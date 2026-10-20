#!/usr/bin/env python3
"""Fail-closed SPIR-V robustness lowering for an isolated Vulkan adapter.

This does NOT advertise VK_EXT_robustness2. The caller binds a real metadata
SSBO and substitutes real dummy allocations for null descriptors. The compiler
guards memory operations, not just the descriptor used for them. Unsupported
pointer/image forms are errors, not silently unprotected fallbacks.
"""
import argparse, dataclasses, hashlib, json, pathlib, re, subprocess

@dataclasses.dataclass
class Ins:
    result: str | None
    op: str
    args: list
    text: str

def parse(line):
    t = line.strip()
    if not t or t.startswith(';'): return Ins(None, '', [], line)
    m = re.match(r'(?:(%\S+)\s*=\s*)?(Op\w+)\s*(.*)', t)
    if not m: raise ValueError('Cannot parse: ' + t)
    return Ins(m[1], m[2], re.findall(r'"[^"]*"|\S+', m[3]), line)

class Lower:
    def __init__(self, text, binding, descriptor_counts=None, metadata_set=31):
        self.ins = [parse(x) for x in text.splitlines()]
        self.defs = {x.result:x for x in self.ins if x.result}
        self.binding = binding
        self.metadata_set = metadata_set
        self.serial = 0
        self.annotations, self.globals, self.helpers = [], [], []
        self.resources = {}
        self.decs, self.members = {}, {}
        self.types = {}
        self.constants = {}
        self.calls = []
        descriptor_counts=descriptor_counts or {}
        for x in self.ins:
            a=x.args
            if x.op=='OpCapability' and a[0] in ('PhysicalStorageBufferAddresses','PhysicalStorageBufferAddressesEXT','VariablePointers','VariablePointersStorageBuffer','Int64Atomics'):
                raise ValueError('Unsupported memory capability: '+a[0])
            if x.op == 'OpDecorate': self.decs.setdefault(a[0], {})[a[1]]=a[2:]
            if x.op == 'OpMemberDecorate': self.members.setdefault((a[0],int(a[1])), {})[a[2]]=a[3:]
            if x.op.startswith('OpType'): self.types[x.result]=x
            if x.op == 'OpConstant':
                try: self.constants[x.result]=int(a[1],0)
                except ValueError: pass
        self.u32=self.type('OpTypeInt',['32','0'])
        self.u64=self.type('OpTypeInt',['64','0'])
        self.bool=self.type('OpTypeBool',[])
        self.void=self.type('OpTypeVoid',[])
        self.zero=self.const(self.u32,0)
        self.zero64=self.const(self.u64,0)
        self.false=self.g('OpConstantFalse',self.bool)
        self.true=self.g('OpConstantTrue',self.bool)
        self.meta4=self.type('OpTypeVector',[self.u32,'4'])
        self.meta_arr=self.g('OpTypeRuntimeArray',self.meta4)
        self.meta_block=self.g('OpTypeStruct',self.meta_arr)
        self.annotations += [f'OpDecorate {self.meta_arr} ArrayStride 16',
            f'OpDecorate {self.meta_block} Block', f'OpMemberDecorate {self.meta_block} 0 Offset 0', f'OpMemberDecorate {self.meta_block} 0 NonWritable']
        self.meta_ptr=self.type('OpTypePointer',['StorageBuffer',self.meta_block])
        self.meta_scalar_ptr=self.type('OpTypePointer',['StorageBuffer',self.u32])
        self.meta=self.g('OpVariable',self.meta_ptr,'StorageBuffer')
        self.annotations += [f'OpDecorate {self.meta} NonWritable', f'OpDecorate {self.meta} DescriptorSet {metadata_set}', f'OpDecorate {self.meta} Binding {binding}']
        slot=0
        for x in self.ins:
            if x.op != 'OpVariable': continue
            d=self.decs.get(x.result,{})
            if 'Binding' not in d: continue
            ds=int(d.get('DescriptorSet',['0'])[0]); bn=int(d['Binding'][0])
            if ds == metadata_set and bn == binding: raise ValueError('Metadata binding collision')
            p=self.types[x.args[0]]
            typ=p.args[1]; content=typ;count=1;descriptor_array=False
            if self.types[typ].op in ('OpTypeArray','OpTypeRuntimeArray'):
                descriptor_array=True;arr=self.types[typ];content=arr.args[0]
                if arr.op=='OpTypeArray':count=self.constants[arr.args[1]]
                else:
                    count=descriptor_counts.get(f'{ds}:{bn}',0)
                    if not isinstance(count,int) or count<=0:raise ValueError('Runtime descriptor array requires explicit allocated count for '+f'{ds}:{bn}')
                if count<=0 or count>1000000:raise ValueError('Descriptor count outside metadata contract')
            kind=self.types[content].op
            if x.args[1] in ('StorageBuffer','Uniform'):
                if kind != 'OpTypeStruct': raise ValueError('Unsupported buffer root')
                rk='buffer'
            elif x.args[1] == 'UniformConstant' and kind in ('OpTypeImage','OpTypeSampledImage','OpTypeSampler'):
                rk='image' if kind != 'OpTypeSampler' else 'sampler'
            else: raise ValueError('Unsupported descriptor class: '+x.text)
            self.resources[x.result]={'set':ds,'binding':bn,'kind':rk,'slot':slot,'type':typ,'contentType':content,'descriptorArray':descriptor_array,'count':count,'storage':x.args[1]}
            slot+=count
        self.slot_count=slot

    def id(self):
        self.serial+=1; return '%r2_'+str(self.serial)
    def g(self,op,*a):
        i=self.id(); self.globals.append(f'{i} = {op} '+ ' '.join(a)); return i
    def type(self,op,a):
        for k,v in self.types.items():
            if v.op==op and v.args==a:return k
        i=self.g(op,*a);self.types[i]=Ins(i,op,a,'');return i
    def const(self,t,v):
        for k,n in self.constants.items():
            if n==v and self.defs[k].args[0]==t:return k
        i=self.g('OpConstant',t,str(v));self.constants[i]=v;self.defs[i]=Ins(i,'OpConstant',[t,str(v)],'');return i
    def null(self,t):return self.g('OpConstantNull',t)
    def typeof(self,v):
        if v in self.defs:return self.defs[v].args[0]
        raise ValueError('No type for '+v)
    def trace(self,p):
        if p in self.resources:return p,[]
        x=self.defs.get(p)
        if x and x.op in ('OpAccessChain','OpInBoundsAccessChain'):
            root,idx=self.trace(x.args[1]);return root,idx+x.args[2:]
        if x and x.op=='OpCopyObject':return self.trace(x.args[1])
        raise ValueError('Unsupported descriptor-derived pointer: '+p)
    def maybe_trace(self,p):
        try:return self.trace(p)
        except ValueError:return None
    def emit(self,body,op,*a):
        i=self.id();body.append(f'{i} = {op} '+' '.join(a));return i
    def index_offset(self,root,indices,body):
        resource=self.resources[root];typ=resource['contentType'];off=self.zero64; ok=self.true
        descriptor_index=None
        if resource['descriptorArray']:
            if not indices:raise ValueError('Missing descriptor array element')
            descriptor_index,indices=indices[0],indices[1:]
            _,ok=self.descriptor_index(root,descriptor_index,body)
        length=self.meta_word(root,1,body,descriptor_index)
        size=self.emit(body,'OpUConvert',self.u64,length)
        for idx in indices:
            t=self.types[typ]
            if t.op=='OpTypeStruct':
                if idx not in self.constants:raise ValueError('Nonconstant struct index')
                n=self.constants[idx];m=self.members.get((typ,n),{})
                if 'Offset' not in m:raise ValueError('Missing explicit member offset')
                if 'MatrixStride' in m:raise ValueError('Matrix layout not yet implemented')
                stride=int(m['Offset'][0]);typ=t.args[n]
                off=self.emit(body,'OpIAdd',self.u64,off,self.const(self.u64,stride))
            elif t.op in ('OpTypeArray','OpTypeRuntimeArray','OpTypeVector'):
                if t.op=='OpTypeVector':stride=self.scalar_bytes(t.args[0]);typ=t.args[0]
                else:
                    st=self.decs.get(typ,{}).get('ArrayStride')
                    if not st:raise ValueError('Missing ArrayStride')
                    stride=int(st[0]);typ=t.args[0]
                it=self.types[self.typeof(idx)]
                if it.op!='OpTypeInt':raise ValueError('Noninteger index')
                wide=self.emit(body,'OpUConvert',self.u64,idx) if it.args[0]!='64' else idx
                if it.args[1]=='1':
                    nonneg=self.emit(body,'OpSGreaterThanEqual',self.bool,idx,self.const(self.typeof(idx),0))
                    ok=self.emit(body,'OpLogicalAnd',self.bool,ok,nonneg)
                # Validate multiplication before computing the byte offset. This
                # protects even 64-bit index overflow, rather than wrapping it.
                le=self.emit(body,'OpULessThanEqual',self.bool,off,size)
                rem=self.emit(body,'OpISub',self.u64,size,off)
                lim=self.emit(body,'OpUDiv',self.u64,rem,self.const(self.u64,stride))
                fits=self.emit(body,'OpULessThanEqual',self.bool,wide,lim)
                ok=self.emit(body,'OpLogicalAnd',self.bool,ok,le)
                ok=self.emit(body,'OpLogicalAnd',self.bool,ok,fits)
                term=self.emit(body,'OpIMul',self.u64,wide,self.const(self.u64,stride))
                off=self.emit(body,'OpIAdd',self.u64,off,term)
            else:raise ValueError('Unsupported access-chain type '+t.op)
        return typ,off,size,ok
    def scalar_bytes(self,t):
        x=self.types[t]
        if x.op not in ('OpTypeInt','OpTypeFloat'):raise ValueError('Unsupported scalar type')
        return int(x.args[0])//8
    def descriptor_index(self,root,index,body):
        if index is None:raise ValueError('Descriptor array requires explicit index')
        t=self.typeof(index);it=self.types[t]
        if it.op!='OpTypeInt' or it.args[0]!='32':raise ValueError('Descriptor indices must be 32bit integers')
        v=index if t==self.u32 else self.emit(body,'OpBitcast',self.u32,index)
        ok=self.emit(body,'OpULessThan',self.bool,v,self.const(self.u32,self.resources[root]['count']))
        safe=self.emit(body,'OpSelect',self.u32,ok,v,self.zero)
        return safe,ok
    def meta_word(self,root,word,body,descriptor_index=None):
        slot=self.const(self.u32,self.resources[root]['slot'])
        if self.resources[root]['descriptorArray']:
            safe,_=self.descriptor_index(root,descriptor_index,body)
            slot=self.emit(body,'OpIAdd',self.u32,slot,safe)
        p=self.emit(body,'OpAccessChain',self.meta_scalar_ptr,self.meta,self.zero,slot,self.const(self.u32,word))
        return self.emit(body,'OpLoad',self.u32,p)
    def make_helper(self,ret,params):
        f=self.id(); ft=self.type('OpTypeFunction',[ret]+[t for _,t in params])
        body=[f'{f} = OpFunction {ret} None {ft}'];mapping={}
        for arg,t in params:
            q=self.id();body.append(f'{q} = OpFunctionParameter {t}');mapping[arg]=q
            if any(k in self.decs.get(arg,{}) for k in ('NonUniform','NonUniformEXT')):
                self.annotations.append(f'OpDecorate {q} NonUniform')
        label=self.id();body.append(label+' = OpLabel')
        return f,body,mapping,label
    def param_list(self,values):
        # Constants and globally declared values may be used directly in helpers.
        seen=[]
        for v in values:
            if v in self.constants:continue
            if v not in seen:seen.append(v)
        return [(v,self.typeof(v)) for v in seen]
    def memory_helper(self,x,root,indices,component=None):
        a=x.args;is_store=x.op in ('OpStore','OpAtomicStore')
        pointer=a[0] if is_store else a[1]
        ptype=self.types[self.typeof(pointer)]
        value_type=ptype.args[1]
        vt=self.types[value_type]
        # Vector accesses have component-wise robustness; a partly valid vector
        # must retain its in-bounds components, not turn the entire vector zero.
        if vt.op=='OpTypeVector' and component is None:
            if x.op not in ('OpLoad','OpStore'):raise ValueError('Vector atomic')
            return self.vector_helper(x,root,indices,value_type)
        self.scalar_bytes(value_type)
        if x.op=='OpLoad' and len(a)!=2:raise ValueError('Load memory operands need explicit validation')
        if x.op=='OpStore' and len(a)!=2:raise ValueError('Store memory operands need explicit validation')
        tail=a[1:] if is_store else a[2:]
        params=self.param_list(indices+tail)
        ret=self.void if is_store else a[0]
        f,body,mapping,_=self.make_helper(ret,params)
        ix=[mapping.get(v,v) for v in indices]
        # index_offset needs parameter type metadata too.
        for old,new in mapping.items():self.defs[new]=Ins(new,'OpFunctionParameter',[self.typeof(old)],'')
        _,offset,size,ok=self.index_offset(root,ix,body)
        live=self.meta_word(root,0,body,ix[0] if self.resources[root]['descriptorArray'] else None)
        live=self.emit(body,'OpINotEqual',self.bool,live,self.zero)
        ok=self.emit(body,'OpLogicalAnd',self.bool,ok,live)
        in_range=self.emit(body,'OpULessThanEqual',self.bool,offset,size)
        remaining=self.emit(body,'OpISub',self.u64,size,offset)
        enough=self.emit(body,'OpUGreaterThanEqual',self.bool,remaining,self.const(self.u64,self.scalar_bytes(value_type)))
        ok=self.emit(body,'OpLogicalAnd',self.bool,ok,in_range)
        ok=self.emit(body,'OpLogicalAnd',self.bool,ok,enough)
        yes,no,merge=self.id(),self.id(),self.id()
        body += [f'OpSelectionMerge {merge} None',f'OpBranchConditional {ok} {yes} {no}',yes+' = OpLabel']
        p=self.emit(body,'OpAccessChain',self.typeof(pointer),root,*ix)
        if any(k in self.decs.get(pointer,{}) for k in ('NonUniform','NonUniformEXT')):
            self.annotations.append(f'OpDecorate {p} NonUniform')
        tail=[mapping.get(v,v) for v in tail]
        if is_store:body.append(x.op+' '+' '.join([p]+tail));v=None
        else:v=self.emit(body,x.op,ret,p,*tail)
        body += [f'OpBranch {merge}',no+' = OpLabel',f'OpBranch {merge}',merge+' = OpLabel']
        if is_store:body.append('OpReturn')
        else:
            result=self.emit(body,'OpPhi',ret,v,yes,self.null(ret),no)
            body.append('OpReturnValue '+result)
        body.append('OpFunctionEnd');self.helpers+=body
        return f,params
    def vector_helper(self,x,root,indices,vt):
        a=x.args;store=x.op=='OpStore';t=self.types[vt];elem,n=t.args[0],int(t.args[1])
        value=a[1] if store else None
        params=self.param_list(indices+([value] if store else []))
        f,body,mapping,_=self.make_helper(self.void if store else vt,params)
        for old,new in mapping.items():self.defs[new]=Ins(new,'OpFunctionParameter',[self.typeof(old)],'')
        ix=[mapping.get(v,v) for v in indices];out=[]
        for i in range(n):
            c=self.const(self.u32,i)
            ptrtype=self.type('OpTypePointer',[self.resources[root]['storage'],elem])
            dummy=self.id();self.defs[dummy]=Ins(dummy,'OpAccessChain',[ptrtype,root]+ix+[c],'')
            if store:
                v=self.emit(body,'OpCompositeExtract',elem,mapping.get(value,value),str(i))
                self.defs[v]=Ins(v,'OpCompositeExtract',[elem],'')
                op=Ins(None,'OpStore',[dummy,v],'')
            else:op=Ins(self.id(),'OpLoad',[elem,dummy],'')
            h,ps=self.memory_helper(op,root,ix+[c],component=i)
            result=self.emit(body,'OpFunctionCall',self.void if store else elem,h,*[v for v,_ in ps])
            out.append(result)
        if store:body.append('OpReturn')
        else:
            v=self.emit(body,'OpCompositeConstruct',vt,*out);body.append('OpReturnValue '+v)
        body.append('OpFunctionEnd');self.helpers+=body
        return f,params
    def image_trace(self,v):
        x=self.defs.get(v)
        if not x:raise ValueError('Unknown image value')
        if x.op=='OpLoad':return self.trace(x.args[1])
        if x.op=='OpSampledImage':
            ir,ix=self.image_trace(x.args[1]);sr,sx=self.image_trace(x.args[2])
            if ix or sx:raise ValueError('Image descriptor arrays unsupported')
            return ir,[]
        if x.op=='OpImage':return self.image_trace(x.args[1])
        raise ValueError('Image value escapes supported direct-load form')
    def image_helper(self,x):
        a=x.args;store=x.op=='OpImageWrite'
        img=a[0] if store else a[1];coord=a[1] if store else a[2]
        root,ix=self.image_trace(img)
        if ix:raise ValueError('Image descriptor arrays unsupported')
        imgt=self.types[self.resources[root]['type']]
        if imgt.op!='OpTypeImage':raise ValueError('Combined image root unsupported')
        # This first adapter has a precise 2D, single-sample, non-array contract.
        if imgt.args[1:5]!=['2D','0','0','0']:raise ValueError('Unsupported image dimension/array/MSAA/depth')
        if x.op=='OpImageSampleExplicitLod':return self.sample_helper(x,root)
        if x.op not in ('OpImageRead','OpImageWrite','OpImageFetch'):raise ValueError('Unsupported image operation '+x.op)
        tail=a[2:] if store else a[3:]
        texel=tail[:1] if store else []
        qualifiers=tail[1:] if store else tail
        if qualifiers and (len(qualifiers)!=1 or not set(qualifiers[0].split('|'))<={'ZeroExtend','SignExtend'}):raise ValueError('Image operands (LOD/offset/etc.) require additional lowering')
        if store and not texel:raise ValueError('ImageWrite missing texel')
        params=self.param_list([coord]+texel)
        ret=self.void if store else a[0]
        f,body,mapping,_=self.make_helper(ret,params)
        co=mapping.get(coord,coord);ct=self.types[self.typeof(coord)]
        if ct.op!='OpTypeVector' or ct.args[1]!='2':raise ValueError('Expected 2D integer coordinates')
        scalar=ct.args[0];st=self.types[scalar]
        if st.op!='OpTypeInt' or st.args[0]!='32':raise ValueError('Image coordinate type unsupported')
        ok=self.emit(body,'OpINotEqual',self.bool,self.meta_word(root,0,body),self.zero)
        for dim in range(2):
            c=self.emit(body,'OpCompositeExtract',scalar,co,str(dim))
            if st.args[1]=='1':
                q=self.emit(body,'OpSGreaterThanEqual',self.bool,c,self.const(scalar,0))
                ok=self.emit(body,'OpLogicalAnd',self.bool,ok,q)
                c=self.emit(body,'OpBitcast',self.u32,c)
            n=self.meta_word(root,dim+1,body)
            q=self.emit(body,'OpULessThan',self.bool,c,n)
            ok=self.emit(body,'OpLogicalAnd',self.bool,ok,q)
        yes,no,merge=self.id(),self.id(),self.id()
        body += [f'OpSelectionMerge {merge} None',f'OpBranchConditional {ok} {yes} {no}',yes+' = OpLabel']
        loaded=self.emit(body,'OpLoad',self.resources[root]['type'],root)
        if store:body.append('OpImageWrite '+' '.join([loaded,co]+[mapping.get(v,v) for v in texel]+qualifiers));val=None
        else:val=self.emit(body,x.op,ret,loaded,co,*qualifiers)
        body += [f'OpBranch {merge}',no+' = OpLabel',f'OpBranch {merge}',merge+' = OpLabel']
        if store:body.append('OpReturn')
        else:
            v=self.emit(body,'OpPhi',ret,val,yes,self.null(ret),no);body.append('OpReturnValue '+v)
        body.append('OpFunctionEnd');self.helpers+=body
        return f,params
    def sample_helper(self,x,root):
        a=x.args
        if len(a)!=5 or 'Lod' not in a[3].split('|') or not set(a[3].split('|'))<={'Lod','ZeroExtend','SignExtend'}:raise ValueError('Only explicit-LOD sampling covered by this adapter')
        sampled=self.defs.get(a[1])
        if not sampled or sampled.op!='OpSampledImage':raise ValueError('Only separate image/sampler bindings supported')
        image_value,sampler_value=sampled.args[1:3]
        sampler_root,indices=self.image_trace(sampler_value)
        if indices:raise ValueError('Sampler descriptor arrays need separate indexing support')
        imgt=self.types[self.resources[root]['type']]
        if imgt.args[1:5]!=['2D','0','0','0'] or imgt.args[5]!='1':raise ValueError('Only non-array, non-depth, non-MSAA 2D sampled images covered')
        ret=a[0];params=self.param_list([a[2],a[4]])
        f,body,mapping,_=self.make_helper(ret,params)
        live=self.emit(body,'OpINotEqual',self.bool,self.meta_word(root,0,body),self.zero)
        yes,no,merge=self.id(),self.id(),self.id()
        body += [f'OpSelectionMerge {merge} None',f'OpBranchConditional {live} {yes} {no}',yes+' = OpLabel']
        im=self.emit(body,'OpLoad',self.resources[root]['type'],root)
        sm=self.emit(body,'OpLoad',self.resources[sampler_root]['type'],sampler_root)
        pair=self.emit(body,'OpSampledImage',sampled.args[0],im,sm)
        val=self.emit(body,'OpImageSampleExplicitLod',ret,pair,mapping.get(a[2],a[2]),a[3],mapping.get(a[4],a[4]))
        body += [f'OpBranch {merge}',no+' = OpLabel',f'OpBranch {merge}',merge+' = OpLabel']
        out=self.emit(body,'OpPhi',ret,val,yes,self.null(ret),no)
        body += ['OpReturnValue '+out,'OpFunctionEnd'];self.helpers+=body
        return f,params
    def array_length_helper(self,x):
        a=x.args;root,indices=self.trace(a[1])
        descriptor_array=self.resources[root]['descriptorArray']
        if len(indices)!=(1 if descriptor_array else 0):raise ValueError('Nested buffer ArrayLength unsupported')
        typ=self.resources[root]['contentType'];member=int(a[2]);t=self.types[typ]
        if t.op!='OpTypeStruct':raise ValueError('ArrayLength root must be struct')
        at=t.args[member]
        if self.types[at].op!='OpTypeRuntimeArray':raise ValueError('ArrayLength requires runtime array')
        offset=int(self.members[(typ,member)]['Offset'][0]);stride=int(self.decs[at]['ArrayStride'][0])
        params=self.param_list(indices)
        f,body,mapping,_=self.make_helper(a[0],params)
        for old,new in mapping.items():self.defs[new]=Ins(new,'OpFunctionParameter',[self.typeof(old)],'')
        index=mapping.get(indices[0],indices[0]) if descriptor_array else None
        length=self.meta_word(root,1,body,index);live=self.meta_word(root,0,body,index)
        ok=self.emit(body,'OpINotEqual',self.bool,live,self.zero)
        if descriptor_array:
            _,valid=self.descriptor_index(root,index,body)
            ok=self.emit(body,'OpLogicalAnd',self.bool,ok,valid)
        enough=self.emit(body,'OpUGreaterThanEqual',self.bool,length,self.const(self.u32,offset))
        ok=self.emit(body,'OpLogicalAnd',self.bool,ok,enough)
        n=self.emit(body,'OpISub',self.u32,length,self.const(self.u32,offset))
        n=self.emit(body,'OpUDiv',self.u32,n,self.const(self.u32,stride))
        n=self.emit(body,'OpSelect',self.u32,ok,n,self.zero)
        if a[0]!=self.u32:n=self.emit(body,'OpUConvert',a[0],n)
        body += ['OpReturnValue '+n,'OpFunctionEnd'];self.helpers+=body
        return f,params
    def lower(self):
        rewritten=[];counts={}
        for x in self.ins:
            a=x.args;hp=None
            if x.op in ('OpLoad','OpStore') or x.op.startswith('OpAtomic'):
                if x.op in ('OpAtomicFlagTestAndSet','OpAtomicFlagClear'):raise ValueError('Atomic flag not implemented')
                ptr=a[0] if x.op in ('OpStore','OpAtomicStore') else a[1]
                tr=self.maybe_trace(ptr)
                if tr and self.resources[tr[0]]['kind']=='buffer':
                    hp=self.memory_helper(x,*tr)
                elif not tr:
                    pt=self.types.get(self.typeof(ptr))
                    if pt and pt.op=='OpTypePointer' and pt.args[0] in ('StorageBuffer','Uniform','PhysicalStorageBuffer'):
                        raise ValueError('Unresolved buffer pointer; refusing unprotected '+x.op)
            elif x.op.startswith('OpImage'):
                if x.op in ('OpImageRead','OpImageWrite','OpImageFetch','OpImageSampleExplicitLod'):hp=self.image_helper(x)
                elif x.op not in ('OpImage',):
                    raise ValueError('Unimplemented image instruction: '+x.op)
            elif x.op=='OpArrayLength':hp=self.array_length_helper(x)
            elif x.op in ('OpCopyMemory','OpCopyMemorySized','OpPtrAccessChain','OpInBoundsPtrAccessChain'):
                raise ValueError('Unsupported memory instruction: '+x.op)
            # Never allow a descriptor-derived pointer to escape through a
            # function, phi, select, cast, or an unsupported instruction.
            if x.op not in ('OpAccessChain','OpInBoundsAccessChain','OpLoad','OpStore','OpName','OpDecorate','OpCopyObject') and not x.op.startswith(('OpType','OpAtomic')):
                for v in a:
                    tr=self.maybe_trace(v)
                    if tr and self.resources[tr[0]]['kind']=='buffer':
                        if x.op not in ('OpEntryPoint','OpArrayLength'):raise ValueError('Buffer pointer escapes through '+x.op)
            if hp:
                f,ps=hp;ret=self.void if x.op in ('OpStore','OpAtomicStore','OpImageWrite') else a[0]
                result=x.result or self.id()
                rewritten.append(f'{result} = OpFunctionCall {ret} {f} '+' '.join(v for v,_ in ps))
                counts[x.op]=counts.get(x.op,0)+1
            else:rewritten.append(x.text)
        # Decorations must precede types; helper declarations must precede
        # functions. Type and constant dependencies are emitted in creation order.
        first_type=next(i for i,x in enumerate(self.ins) if x.op.startswith('OpType'))
        first_function=next(i for i,x in enumerate(self.ins) if x.op=='OpFunction')
        version=next((x.text for x in self.ins if '; Version:' in x.text),'')
        if not any(x.op=='OpCapability' and x.args==['Int64'] for x in self.ins):
            cap_at=next(i for i,x in enumerate(self.ins) if x.op!='OpCapability' and x.op and i>0)
            rewritten[cap_at]='OpCapability Int64\n'+rewritten[cap_at]
        if version and float(version.split(':',1)[1])>=1.4:
            for i,x in enumerate(self.ins):
                if x.op=='OpEntryPoint':rewritten[i]+=' '+self.meta
        rewritten[first_type]='\n'.join(self.annotations)+'\n'+rewritten[first_type]
        rewritten[first_function]='\n'.join(self.globals)+'\n'+rewritten[first_function]
        rewritten += self.helpers
        return '\n'.join(rewritten)+'\n',{'contract':'isolated-r2-v1; NOT full VK_EXT_robustness2 advertisement','metadataSet':self.metadata_set,'metadataBinding':self.binding,'metadataEntryWords':4,'metadataSlots':self.slot_count,'resources':self.resources,'loweredOperations':counts,'limitations':['descriptor arrays supported for buffers only; runtime arrays require actual allocated count','no pointer escape/physical pointers','scalar/vector buffer loads/stores and supported atomics only','2D non-array single-sample storage images; separate 2D explicit-LOD sampling only','no image LOD/offset operands, implicit derivatives, depth compares, image queries or image atomics','no nested ArrayLength, matrices or copy-memory yet']}

def main():
    p=argparse.ArgumentParser();p.add_argument('input');p.add_argument('output');p.add_argument('--metadata-binding',type=int,default=31);p.add_argument('--descriptor-counts');args=p.parse_args()
    inp,out=pathlib.Path(args.input),pathlib.Path(args.output)
    text=subprocess.check_output(['/usr/local/bin/spirv-dis','--raw-id',str(inp)],text=True)
    ver=int.from_bytes(inp.read_bytes()[4:8],'little');minor=(ver>>8)&255
    if minor<3 or minor>6:raise ValueError('Only SPIR-V1.3 through1.6 supported by this adapter')
    counts=json.loads(pathlib.Path(args.descriptor_counts).read_text()) if args.descriptor_counts else {}
    result,manifest=Lower(text,args.metadata_binding,counts).lower()
    asm=out.with_suffix('.spvasm');asm.write_text(result)
    subprocess.run(['/usr/local/bin/spirv-as','--target-env',f'spv1.{minor}',str(asm),'-o',str(out)],check=True)
    target='vulkan1.1' if minor==3 else 'vulkan1.2' if minor<6 else 'vulkan1.3'
    subprocess.run(['/usr/local/bin/spirv-val','--target-env',target,str(out)],check=True)
    manifest['inputSha256']=hashlib.sha256(inp.read_bytes()).hexdigest();manifest['outputSha256']=hashlib.sha256(out.read_bytes()).hexdigest()
    out.with_suffix('.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(manifest['loweredOperations']))
if __name__=='__main__':main()
