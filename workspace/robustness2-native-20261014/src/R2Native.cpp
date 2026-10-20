#include "R2Native.h"
#include <spirv-tools/libspirv.hpp>
#include <algorithm>
#include <optional>
#include <regex>
#include <set>
#include <sstream>
#include <stdexcept>

namespace {
using S=std::string;using V=std::vector<S>;
struct I {S id,op;V a;S text;};
struct Trace {S root;V ix;};
using Params=std::vector<std::pair<S,S>>;
S join(const V& v){S out;for(auto& s:v){if(!out.empty())out+=' ';out+=s;}return out;}
V tail(const V& v,size_t n){return V(v.begin()+n,v.end());}
V cat(V a,const V& b){a.insert(a.end(),b.begin(),b.end());return a;}
bool starts(const S& a,const S& b){return a.compare(0,b.size(),b)==0;}
bool in(const S& x,std::initializer_list<S> values){return std::find(values.begin(),values.end(),x)!=values.end();}
uint64_t number(const S& s){size_t n=0;auto v=std::stoull(s,&n,0);if(n!=s.size())throw std::runtime_error("Not an integer: "+s);return v;}
I parse(const S& line){
    static const std::regex pattern(R"(^\s*(?:(%\S+)\s*=\s*)?(Op\w+)\s*(.*)$)");
    static const std::regex token(R"("[^"]*"|\S+)");
    I x;x.text=line;auto p=line.find_first_not_of(" \t\r");if(p==S::npos||line[p]==';')return x;
    std::smatch m;if(!std::regex_match(line,m,pattern))throw std::runtime_error("Cannot parse SPIR-V assembly");
    x.id=m[1];x.op=m[2];S rest=m[3];for(std::sregex_iterator i(rest.begin(),rest.end(),token),end;i!=end;++i)x.a.push_back(i->str());return x;
}
struct Helper {S f;V body;Params params;std::map<S,S> mapping;};
struct Offset {S type,offset,size,ok;};
class Lower {
    std::vector<I> instructions;
    std::map<S,I> defs,types;
    std::map<S,std::map<S,V>> decs;
    std::map<std::pair<S,uint32_t>,std::map<S,V>> members;
    std::map<S,uint64_t> constants;
    std::map<S,R2Resource> resources;
    V annotations,globals,helpers;
    S u32,u64,boolean,voidType,zero,zero64,no,yes,meta,metaPtr;
    uint32_t serial=0,slots=0,physical=0,guarded=0;
    S id(){return "%r2n_"+std::to_string(++serial);}
    S global(const S& op,const V& args){S n=id();globals.push_back(n+" = "+op+" "+join(args));return n;}
    S type(const S& op,const V& args){for(auto& [n,t]:types)if(t.op==op&&t.a==args)return n;S n=global(op,args);types[n]={n,op,args,{}};return n;}
    S constant(const S& t,uint64_t value){for(auto& [n,v]:constants)if(v==value&&defs.at(n).a[0]==t)return n;S n=global("OpConstant",{t,std::to_string(value)});constants[n]=value;defs[n]={n,"OpConstant",{t,std::to_string(value)},{}};return n;}
    S typeof_(const S& n){auto i=defs.find(n);if(i==defs.end()||i->second.a.empty())throw std::runtime_error("Unknown value type: "+n);return i->second.a[0];}
    I typ(const S& n){auto i=types.find(n);if(i==types.end())throw std::runtime_error("Unknown type: "+n);return i->second;}
    S emit(V& body,const S& op,const V& a){S n=id();body.push_back(n+" = "+op+" "+join(a));return n;}
    bool decorated(const S& n,const S& d){return decs[n].count(d)!=0;}
    bool nonuniform(const S& n){return decorated(n,"NonUniform")||decorated(n,"NonUniformEXT");}
    Trace trace(const S& n,unsigned depth=0){
        if(depth>128)throw std::runtime_error("Pointer trace depth exceeded");
        if(resources.count(n))return {n,{}};
        auto i=defs.find(n);if(i!=defs.end()){
            auto& x=i->second;
            if(in(x.op,{"OpAccessChain","OpInBoundsAccessChain"})){auto tr=trace(x.a.at(1),depth+1);tr.ix=cat(tr.ix,tail(x.a,2));return tr;}
            if(x.op=="OpCopyObject")return trace(x.a.at(1),depth+1);
        }
        throw std::runtime_error("Unsupported descriptor pointer: "+n);
    }
    std::optional<Trace> maybeTrace(const S& n){try{return trace(n);}catch(const std::exception&){return {};}}
    uint32_t bytes(const S& t){auto x=typ(t);if(x.op=="OpTypePointer"&&x.a[0]=="PhysicalStorageBuffer")return 8;if(!in(x.op,{"OpTypeInt","OpTypeFloat"}))throw std::runtime_error("Unsupported scalar memory type");auto b=number(x.a[0]);if(b!=32&&b!=64)throw std::runtime_error("8/16-bit memory forms not qualified");return uint32_t(b/8);}
    std::pair<S,S> descriptorIndex(const S& root,const S& index,V& body){
        auto t=typeof_(index);auto it=typ(t);if(it.op!="OpTypeInt"||it.a[0]!="32")throw std::runtime_error("Descriptor index must be a 32-bit integer");
        auto v=t==u32?index:emit(body,"OpBitcast",{u32,index});auto valid=emit(body,"OpULessThan",{boolean,v,constant(u32,resources.at(root).count)});auto safe=emit(body,"OpSelect",{u32,valid,v,zero});return {safe,valid};
    }
    S word(const S& root,uint32_t component,V& body,const S& index={}){
        auto& r=resources.at(root);S slot=constant(u32,r.slot);if(r.array){auto safe=descriptorIndex(root,index,body).first;slot=emit(body,"OpIAdd",{u32,slot,safe});}
        auto p=emit(body,"OpAccessChain",{metaPtr,meta,zero,slot,constant(u32,component)});return emit(body,"OpLoad",{u32,p});
    }
    Offset offset(const S& root,V indices,V& body){
        const auto r=resources.at(root);S t=r.content,off=zero64,ok=yes,index;
        if(r.array){if(indices.empty())throw std::runtime_error("Missing descriptor array index");index=indices[0];indices.erase(indices.begin());ok=descriptorIndex(root,index,body).second;}
        S length=word(root,1,body,index),size=emit(body,"OpUConvert",{u64,length});
        for(auto& ix:indices){auto tt=typ(t);
            if(tt.op=="OpTypeStruct"){
                if(!constants.count(ix))throw std::runtime_error("Nonconstant struct index");auto n=constants.at(ix);auto m=members[{t,uint32_t(n)}];
                if(!m.count("Offset")||m.count("MatrixStride"))throw std::runtime_error("Missing offset or unsupported matrix layout");
                off=emit(body,"OpIAdd",{u64,off,constant(u64,number(m.at("Offset")[0]))});t=tt.a.at(n);
            }else if(in(tt.op,{"OpTypeArray","OpTypeRuntimeArray","OpTypeVector"})){
                uint64_t stride;
                if(tt.op=="OpTypeVector")stride=bytes(tt.a[0]);else{if(!decs[t].count("ArrayStride"))throw std::runtime_error("Missing array stride");stride=number(decs[t]["ArrayStride"][0]);}
                t=tt.a[0];if(!stride)throw std::runtime_error("Zero stride");auto it=typ(typeof_(ix));if(it.op!="OpTypeInt")throw std::runtime_error("Noninteger index");
                S wide=it.a[0]=="64"?ix:emit(body,"OpUConvert",{u64,ix});
                if(it.a[1]=="1"){auto positive=emit(body,"OpSGreaterThanEqual",{boolean,ix,constant(typeof_(ix),0)});ok=emit(body,"OpLogicalAnd",{boolean,ok,positive});}
                auto le=emit(body,"OpULessThanEqual",{boolean,off,size});auto remaining=emit(body,"OpISub",{u64,size,off});auto limit=emit(body,"OpUDiv",{u64,remaining,constant(u64,stride)});auto fits=emit(body,"OpULessThanEqual",{boolean,wide,limit});ok=emit(body,"OpLogicalAnd",{boolean,ok,le});ok=emit(body,"OpLogicalAnd",{boolean,ok,fits});auto term=emit(body,"OpIMul",{u64,wide,constant(u64,stride)});off=emit(body,"OpIAdd",{u64,off,term});
            }else throw std::runtime_error("Unsupported access-chain type: "+tt.op);
        }return {t,off,size,ok};
    }
    Params params(const V& values){Params out;std::set<S> seen;for(auto& v:values)if(!constants.count(v)&&seen.insert(v).second)out.push_back({v,typeof_(v)});return out;}
    Helper helper(const S& ret,const V& values){
        Helper h;h.f=id();h.params=params(values);V signature{ret};for(auto& p:h.params)signature.push_back(p.second);auto ft=type("OpTypeFunction",signature);h.body.push_back(h.f+" = OpFunction "+ret+" None "+ft);
        for(auto& [arg,t]:h.params){auto p=id();h.mapping[arg]=p;h.body.push_back(p+" = OpFunctionParameter "+t);defs[p]={p,"OpFunctionParameter",{t},{}};if(nonuniform(arg))annotations.push_back("OpDecorate "+p+" NonUniform");}
        h.body.push_back(id()+" = OpLabel");return h;
    }
    S mapped(const Helper& h,const S& v){auto i=h.mapping.find(v);return i==h.mapping.end()?v:i->second;}
    V mapped(const Helper& h,V v){for(auto& n:v)n=mapped(h,n);return v;}
    void finish(Helper& h){helpers=cat(helpers,h.body);}
    S zeroValue(const S& t,V& body){auto x=typ(t);if(x.op=="OpTypePointer"&&x.a[0]=="PhysicalStorageBuffer")return emit(body,"OpConvertUToPtr",{t,zero64});return global("OpConstantNull",{t});}
    void endSelection(Helper& h,const S& ret,const S& value,const S& good,const S& bad,const S& merge,bool store){
        auto& b=h.body;b.push_back("OpBranch "+merge);b.push_back(bad+" = OpLabel");S null;if(!store)null=zeroValue(ret,b);b.push_back("OpBranch "+merge);b.push_back(merge+" = OpLabel");
        if(store)b.push_back("OpReturn");else{auto result=emit(b,"OpPhi",{ret,value,good,null,bad});b.push_back("OpReturnValue "+result);}b.push_back("OpFunctionEnd");finish(h);
    }
    Helper vectorMemory(const I& x,const S& root,const V& indices,const S& vt){
        bool store=x.op=="OpStore";auto t=typ(vt);S elem=t.a[0];unsigned count=unsigned(number(t.a[1]));V values=indices;if(store)values.push_back(x.a[1]);auto h=helper(store?voidType:vt,values);auto ix=mapped(h,indices);V out;
        for(unsigned k=0;k<count;k++){
            auto c=constant(u32,k);auto pt=type("OpTypePointer",{resources.at(root).storage,elem});auto p=id();auto indexes=cat(ix,V{c});defs[p]={p,"OpAccessChain",cat(V{pt,root},indexes),{}};I op;
            if(store){auto v=emit(h.body,"OpCompositeExtract",{elem,mapped(h,x.a[1]),std::to_string(k)});defs[v]={v,"OpCompositeExtract",{elem},{}};op={"","OpStore",{p,v},{}};}
            else op={id(),"OpLoad",{elem,p},{}};
            auto inner=memory(op,root,indexes,true);V args{store?voidType:elem,inner.f};for(auto& param:inner.params)args.push_back(param.first);out.push_back(emit(h.body,"OpFunctionCall",args));
        }
        if(store)h.body.push_back("OpReturn");else{auto result=emit(h.body,"OpCompositeConstruct",cat(V{vt},out));h.body.push_back("OpReturnValue "+result);}h.body.push_back("OpFunctionEnd");finish(h);return h;
    }
    Helper memory(const I& x,const S& root,const V& indices,bool component=false){
        bool store=in(x.op,{"OpStore","OpAtomicStore"});auto pointer=x.a.at(store?0:1);auto valueType=typ(typeof_(pointer)).a[1];auto vt=typ(valueType);
        if(vt.op=="OpTypeVector"&&!component){if(!in(x.op,{"OpLoad","OpStore"}))throw std::runtime_error("Vector atomic");return vectorMemory(x,root,indices,valueType);}
        auto sizeBytes=bytes(valueType);if(in(x.op,{"OpLoad","OpStore"})&&x.a.size()!=2)throw std::runtime_error("Unqualified logical memory operands");
        V suffix=tail(x.a,store?1:2);S ret=store?voidType:x.a[0];auto h=helper(ret,cat(indices,suffix));auto ix=mapped(h,indices);auto o=offset(root,ix,h.body);
        auto live=word(root,0,h.body,resources.at(root).array?ix.at(0):S{});live=emit(h.body,"OpINotEqual",{boolean,live,zero});auto ok=emit(h.body,"OpLogicalAnd",{boolean,o.ok,live});auto inside=emit(h.body,"OpULessThanEqual",{boolean,o.offset,o.size});auto remaining=emit(h.body,"OpISub",{u64,o.size,o.offset});auto enough=emit(h.body,"OpUGreaterThanEqual",{boolean,remaining,constant(u64,sizeBytes)});ok=emit(h.body,"OpLogicalAnd",{boolean,ok,inside});ok=emit(h.body,"OpLogicalAnd",{boolean,ok,enough});
        auto good=id(),bad=id(),merge=id();h.body=cat(h.body,{"OpSelectionMerge "+merge+" None","OpBranchConditional "+ok+" "+good+" "+bad,good+" = OpLabel"});
        auto p=emit(h.body,"OpAccessChain",cat(V{typeof_(pointer),root},ix));if(nonuniform(pointer))annotations.push_back("OpDecorate "+p+" NonUniform");auto suffixMapped=mapped(h,suffix);S value;
        if(store)h.body.push_back(x.op+" "+join(cat(V{p},suffixMapped)));else value=emit(h.body,x.op,cat(V{ret,p},suffixMapped));endSelection(h,ret,value,good,bad,merge,store);return h;
    }
    Trace imageTrace(const S& v,unsigned depth=0){
        if(depth>128)throw std::runtime_error("Image trace depth exceeded");auto i=defs.find(v);if(i==defs.end())throw std::runtime_error("Unknown image");auto x=i->second;
        if(x.op=="OpLoad")return trace(x.a.at(1));
        if(x.op=="OpSampledImage"){auto ir=imageTrace(x.a.at(1),depth+1),sr=imageTrace(x.a.at(2),depth+1);if(!ir.ix.empty()||!sr.ix.empty())throw std::runtime_error("Image/sampler descriptor arrays unsupported");return ir;}
        if(x.op=="OpImage")return imageTrace(x.a.at(1),depth+1);throw std::runtime_error("Unsupported image value escape");
    }
    bool imageQualifiers(const S& s,bool lod){std::istringstream stream(s);S token;bool found=false;while(std::getline(stream,token,'|')){if(token=="Lod"&&lod)found=true;else if(!in(token,{"ZeroExtend","SignExtend"}))return false;}return !lod||found;}
    Helper sample(const I& x,const S& root){
        auto a=x.a;if(a.size()!=5||!imageQualifiers(a[3],true))throw std::runtime_error("Only explicit-LOD sampling covered");auto si=defs.at(a[1]);if(si.op!="OpSampledImage")throw std::runtime_error("Combined sampler root unsupported");auto sampler=imageTrace(si.a[2]);if(!sampler.ix.empty())throw std::runtime_error("Sampler arrays unsupported");
        auto it=typ(resources.at(root).type);if(it.a.at(5)!="1")throw std::runtime_error("Expected sampled image");auto h=helper(a[0],{a[2],a[4]});auto live=emit(h.body,"OpINotEqual",{boolean,word(root,0,h.body),zero});auto good=id(),bad=id(),merge=id();h.body=cat(h.body,{"OpSelectionMerge "+merge+" None","OpBranchConditional "+live+" "+good+" "+bad,good+" = OpLabel"});auto im=emit(h.body,"OpLoad",{resources.at(root).type,root});auto sm=emit(h.body,"OpLoad",{resources.at(sampler.root).type,sampler.root});auto pair=emit(h.body,"OpSampledImage",{si.a[0],im,sm});auto val=emit(h.body,x.op,{a[0],pair,mapped(h,a[2]),a[3],mapped(h,a[4])});endSelection(h,a[0],val,good,bad,merge,false);return h;
    }
    Helper image(const I& x){
        auto a=x.a;bool store=x.op=="OpImageWrite";auto img=a.at(store?0:1),coord=a.at(store?1:2);auto tr=imageTrace(img);if(!tr.ix.empty())throw std::runtime_error("Image descriptor arrays unsupported");auto r=resources.at(tr.root);auto it=typ(r.type);
        if(it.op!="OpTypeImage"||it.a.size()<7||V(it.a.begin()+1,it.a.begin()+5)!=V{"2D","0","0","0"})throw std::runtime_error("Image dimension/array/depth/MSAA form unsupported");
        if(x.op=="OpImageSampleExplicitLod")return sample(x,tr.root);
        auto suffix=tail(a,store?2:3);V texel,qualifiers;if(store){if(suffix.empty())throw std::runtime_error("Missing image texel");texel={suffix[0]};qualifiers=tail(suffix,1);}else qualifiers=suffix;
        if(!qualifiers.empty()&&(qualifiers.size()!=1||!imageQualifiers(qualifiers[0],false)))throw std::runtime_error("Unsupported image operands");
        auto ct=typ(typeof_(coord));if(ct.op!="OpTypeVector"||ct.a.at(1)!="2")throw std::runtime_error("Expected 2D coordinates");auto scalar=ct.a[0];auto st=typ(scalar);if(st.op!="OpTypeInt"||st.a[0]!="32")throw std::runtime_error("Expected integer image coordinates");
        S ret=store?voidType:a[0];auto h=helper(ret,cat(V{coord},texel));S co=mapped(h,coord);auto ok=emit(h.body,"OpINotEqual",{boolean,word(tr.root,0,h.body),zero});for(unsigned dim=0;dim<2;dim++){auto c=emit(h.body,"OpCompositeExtract",{scalar,co,std::to_string(dim)});if(st.a[1]=="1"){auto q=emit(h.body,"OpSGreaterThanEqual",{boolean,c,constant(scalar,0)});ok=emit(h.body,"OpLogicalAnd",{boolean,ok,q});c=emit(h.body,"OpBitcast",{u32,c});}auto n=word(tr.root,dim+1,h.body);auto q=emit(h.body,"OpULessThan",{boolean,c,n});ok=emit(h.body,"OpLogicalAnd",{boolean,ok,q});}
        auto good=id(),bad=id(),merge=id();h.body=cat(h.body,{"OpSelectionMerge "+merge+" None","OpBranchConditional "+ok+" "+good+" "+bad,good+" = OpLabel"});auto loaded=emit(h.body,"OpLoad",{r.type,tr.root});S val;
        if(store)h.body.push_back("OpImageWrite "+join(cat(cat(V{loaded,co},mapped(h,texel)),qualifiers)));else val=emit(h.body,x.op,cat(V{ret,loaded,co},qualifiers));endSelection(h,ret,val,good,bad,merge,store);return h;
    }
    Helper arrayLength(const I& x){
        auto a=x.a;auto tr=trace(a[1]);auto r=resources.at(tr.root);if(tr.ix.size()!=(r.array?1:0))throw std::runtime_error("Nested ArrayLength unsupported");auto t=typ(r.content);auto member=number(a[2]);if(t.op!="OpTypeStruct")throw std::runtime_error("ArrayLength struct expected");auto at=t.a.at(member);auto arr=typ(at);if(arr.op!="OpTypeRuntimeArray")throw std::runtime_error("ArrayLength requires runtime member");auto offset=number(members.at({r.content,uint32_t(member)}).at("Offset")[0]);auto stride=number(decs.at(at).at("ArrayStride")[0]);if(!stride)throw std::runtime_error("Zero runtime stride");auto h=helper(a[0],tr.ix);S index=r.array?mapped(h,tr.ix[0]):S{};auto length=word(tr.root,1,h.body,index),live=word(tr.root,0,h.body,index);auto ok=emit(h.body,"OpINotEqual",{boolean,live,zero});if(r.array)ok=emit(h.body,"OpLogicalAnd",{boolean,ok,descriptorIndex(tr.root,index,h.body).second});auto enough=emit(h.body,"OpUGreaterThanEqual",{boolean,length,constant(u32,offset)});ok=emit(h.body,"OpLogicalAnd",{boolean,ok,enough});auto n=emit(h.body,"OpISub",{u32,length,constant(u32,offset)});n=emit(h.body,"OpUDiv",{u32,n,constant(u32,stride)});n=emit(h.body,"OpSelect",{u32,ok,n,zero});if(a[0]!=u32)n=emit(h.body,"OpUConvert",{a[0],n});h.body=cat(h.body,{"OpReturnValue "+n,"OpFunctionEnd"});finish(h);return h;
    }
public:
    Lower(const S& text,const std::map<std::pair<uint32_t,uint32_t>,uint32_t>& counts){
        std::istringstream input(text);S line;while(std::getline(input,line)){auto x=parse(line);instructions.push_back(x);if(!x.id.empty())defs[x.id]=x;
            if(x.op=="OpCapability"&&in(x.a[0],{"VariablePointers","VariablePointersStorageBuffer","Int64Atomics"}))throw std::runtime_error("Unsupported memory capability: "+x.a[0]);
            if(x.op=="OpDecorate")decs[x.a[0]][x.a[1]]=tail(x.a,2);
            if(x.op=="OpMemberDecorate")members[{x.a[0],uint32_t(number(x.a[1]))}][x.a[2]]=tail(x.a,3);
            if(starts(x.op,"OpType"))types[x.id]=x;
            if(x.op=="OpConstant"){try{constants[x.id]=number(x.a[1]);}catch(const std::exception&){} }
            if(x.op=="OpEntryPoint"&&!in(x.a[0],{"Vertex","Fragment","GLCompute"}))throw std::runtime_error("Shader stage unsupported by native prototype");
        }
        u32=type("OpTypeInt",{"32","0"});u64=type("OpTypeInt",{"64","0"});boolean=type("OpTypeBool",{});voidType=type("OpTypeVoid",{});zero=constant(u32,0);zero64=constant(u64,0);no=global("OpConstantFalse",{boolean});yes=global("OpConstantTrue",{boolean});auto vec=type("OpTypeVector",{u32,"4"});auto arr=global("OpTypeRuntimeArray",{vec});auto block=global("OpTypeStruct",{arr});annotations={"OpDecorate "+arr+" ArrayStride 16","OpDecorate "+block+" Block","OpMemberDecorate "+block+" 0 Offset 0","OpMemberDecorate "+block+" 0 NonWritable"};auto pt=type("OpTypePointer",{"StorageBuffer",block});metaPtr=type("OpTypePointer",{"StorageBuffer",u32});meta=global("OpVariable",{pt,"StorageBuffer"});annotations=cat(annotations,{"OpDecorate "+meta+" NonWritable","OpDecorate "+meta+" DescriptorSet 31","OpDecorate "+meta+" Binding 0"});
        for(auto& x:instructions){if(x.op!="OpVariable"||!decs[x.id].count("Binding"))continue;auto d=decs[x.id];R2Resource r;r.set=d.count("DescriptorSet")?uint32_t(number(d["DescriptorSet"][0])):0;r.binding=uint32_t(number(d["Binding"][0]));if(r.set==31&&r.binding==0)throw std::runtime_error("Reserved metadata binding collision");auto pt=typ(x.a[0]);r.type=r.content=pt.a[1];r.storage=x.a[1];auto ct=typ(r.type);
            if(in(ct.op,{"OpTypeArray","OpTypeRuntimeArray"})){r.array=true;r.content=ct.a[0];if(ct.op=="OpTypeArray")r.count=uint32_t(constants.at(ct.a[1]));else{auto c=counts.find({r.set,r.binding});if(c==counts.end())throw std::runtime_error("Runtime descriptor count missing");r.count=c->second;}if(!r.count||r.count>256)throw std::runtime_error("Descriptor count exceeds prototype limit");}
            auto kind=typ(r.content).op;if(in(r.storage,{"StorageBuffer","Uniform"})){if(kind!="OpTypeStruct")throw std::runtime_error("Unsupported buffer root");r.buffer=true;}else if(r.storage=="UniformConstant"&&in(kind,{"OpTypeImage","OpTypeSampledImage","OpTypeSampler"}))r.sampler=kind=="OpTypeSampler";else throw std::runtime_error("Unsupported descriptor class");r.slot=slots;slots+=r.count;if(slots>256)throw std::runtime_error("Metadata limit exceeded");resources[x.id]=r;
        }
    }
    S lower(unsigned minor,R2NativeResult& result){
        V lines;for(auto& x:instructions){auto a=x.a;std::optional<Helper> h;
            if(in(x.op,{"OpLoad","OpStore"})||starts(x.op,"OpAtomic")){
                if(in(x.op,{"OpAtomicFlagTestAndSet","OpAtomicFlagClear"}))throw std::runtime_error("Atomic flags unsupported");S pointer=a.at(in(x.op,{"OpStore","OpAtomicStore"})?0:1);auto tr=maybeTrace(pointer);
                if(tr&&resources.at(tr->root).buffer)h=memory(x,tr->root,tr->ix);
                else if(!tr){auto pt=typ(typeof_(pointer));if(pt.op=="OpTypePointer"){
                    if(in(pt.a[0],{"StorageBuffer","Uniform"}))throw std::runtime_error("Unresolved logical descriptor pointer; no unprotected fallback");
                    if(pt.a[0]=="PhysicalStorageBuffer")++physical;
                }}
            }else if(starts(x.op,"OpImage")){
                if(in(x.op,{"OpImageRead","OpImageWrite","OpImageFetch","OpImageSampleExplicitLod"}))h=image(x);else if(x.op!="OpImage")throw std::runtime_error("Unsupported image instruction: "+x.op);
            }else if(x.op=="OpArrayLength")h=arrayLength(x);
            else if(in(x.op,{"OpCopyMemory","OpCopyMemorySized","OpPtrAccessChain","OpInBoundsPtrAccessChain"}))throw std::runtime_error("Unsupported memory instruction: "+x.op);
            if(!in(x.op,{"OpAccessChain","OpInBoundsAccessChain","OpLoad","OpStore","OpName","OpDecorate","OpCopyObject"})&&!starts(x.op,"OpType")&&!starts(x.op,"OpAtomic"))for(auto& v:a){auto tr=maybeTrace(v);if(tr&&resources.at(tr->root).buffer&&!in(x.op,{"OpEntryPoint","OpArrayLength"}))throw std::runtime_error("Logical buffer pointer escape through "+x.op);}
            if(h){S ret=in(x.op,{"OpStore","OpAtomicStore","OpImageWrite"})?voidType:a[0];V args{ret,h->f};for(auto& p:h->params)args.push_back(p.first);lines.push_back((x.id.empty()?id():x.id)+" = OpFunctionCall "+join(args));++guarded;}else lines.push_back(x.text);
        }
        size_t typeAt=instructions.size(),functionAt=instructions.size();bool int64=false;
        for(size_t i=0;i<instructions.size();i++){auto& x=instructions[i];if(starts(x.op,"OpType")&&typeAt==instructions.size())typeAt=i;if(x.op=="OpFunction"&&functionAt==instructions.size())functionAt=i;if(x.op=="OpCapability"&&x.a==V{"Int64"})int64=true;if(minor>=4&&x.op=="OpEntryPoint")lines[i]+=" "+meta;}
        if(!int64){auto i=std::find_if(instructions.begin(),instructions.end(),[](auto& x){return !x.op.empty()&&x.op!="OpCapability";});if(i==instructions.end())throw std::runtime_error("Missing memory model");lines[size_t(i-instructions.begin())]="OpCapability Int64\n"+lines[size_t(i-instructions.begin())];}
        if(typeAt==instructions.size()||functionAt==instructions.size())throw std::runtime_error("Missing shader functions");S out;for(size_t i=0;i<lines.size();i++){if(i==typeAt)for(auto& s:annotations)out+=s+'\n';if(i==functionAt)for(auto& s:globals)out+=s+'\n';out+=lines[i]+'\n';}for(auto& s:helpers)out+=s+'\n';
        for(auto& [n,r]:resources)result.resources.push_back(r);result.slots=slots;result.physicalAccesses=physical;result.guardedOperations=guarded;return out;
    }
};
}

bool r2NativeLower(const std::vector<uint32_t>& input,const std::map<std::pair<uint32_t,uint32_t>,uint32_t>& counts,R2NativeResult& output,std::string& error){
    try{
        output={};if(input.size()<5||input[0]!=0x07230203)throw std::runtime_error("Invalid SPIR-V header");unsigned minor=(input[1]>>8)&255;if(minor<3||minor>6)throw std::runtime_error("Only SPIR-V 1.3..1.6 supported");
        spv_target_env env=minor==3?SPV_ENV_VULKAN_1_1:minor<6?SPV_ENV_VULKAN_1_2:SPV_ENV_VULKAN_1_3;spvtools::SpirvTools tools(env);
        tools.SetMessageConsumer([&](spv_message_level_t,const char*,const spv_position_t& p,const char* msg){error+=std::to_string(p.index)+": "+msg+"\n";});
        if(!tools.Validate(input))throw std::runtime_error("Input SPIR-V validation failed");S disassembly;if(!tools.Disassemble(input,&disassembly,SPV_BINARY_TO_TEXT_OPTION_INDENT))throw std::runtime_error("Native disassembly failed");
        Lower lower(disassembly,counts);output.assembly=lower.lower(minor,output);
        if(!output.slots){output.binary=input;output.assembly=disassembly;return true;}
        spv_target_env assembleEnv=minor==3?SPV_ENV_UNIVERSAL_1_3:minor==4?SPV_ENV_UNIVERSAL_1_4:minor==5?SPV_ENV_UNIVERSAL_1_5:SPV_ENV_UNIVERSAL_1_6;spvtools::SpirvTools assembler(assembleEnv);assembler.SetMessageConsumer([&](spv_message_level_t,const char*,const spv_position_t& p,const char* msg){error+=std::to_string(p.line)+": "+msg+"\n";});
        if(!assembler.Assemble(output.assembly,&output.binary)||!tools.Validate(output.binary))throw std::runtime_error("Native output validation failed");return true;
    }catch(const std::exception& e){error+=e.what();return false;}
}
