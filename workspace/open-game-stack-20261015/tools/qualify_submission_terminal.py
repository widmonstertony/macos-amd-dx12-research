#!/usr/bin/env python3
"""CPU-only exact-source terminal provenance qualification. Never loads Metal.

Extracts the current Native struct unchanged except Objective-C id -> void*,
then adapts the two exact callsite tails to CPU stubs. No Native file is edited.
"""
from __future__ import annotations
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT=Path(__file__).resolve().parents[1]
SOURCE=ROOT/'native-vendor/MoltenVK-05604465d691118cfd20f53a48ecf1aad9c12f93/MoltenVK/MoltenVK/GPUObjects/MVKQueue.mm'


def block(source,anchor):
    start=source.index(anchor);opening=source.index('{',start);depth=0;state='code';i=opening
    while i<len(source):
        pair=source[i:i+2];char=source[i]
        if state=='line':
            if char=='\n':state='code'
        elif state=='block':
            if pair=='*/':state='code';i+=1
        elif state in ('"',"'"):
            if char=='\\':i+=1
            elif char==state:state='code'
        elif pair=='//':state='line';i+=1
        elif pair=='/*':state='block';i+=1
        elif char in ('"',"'"):state=char
        elif char=='{':depth+=1
        elif char=='}':
            depth-=1
            if depth==0:return source[start:i+1]
        i+=1
    raise ValueError('Unbalanced source block: '+anchor)


def tail(function):
    start=function.index('VkResult rslt =')
    return function[start:function.rfind('}')]


def adapt_tail(source,present=False):
    result=source.replace('@"','"')
    result=result.replace('[mtlCmdBuff commit]','mockCommit(mtlCmdBuff)')
    result=result.replace('[mtlCmdBuff release]','mockRelease(mtlCmdBuff)')
    if present:
        old='[mtlCmdBuff addCompletedHandler: ^(id<MTLCommandBuffer> mtlCB) { this->finish(); }]'
        if result.count(old)!=1:raise ValueError('Present completion registration changed; review adaptation')
        result=result.replace(old,'mockAddCompletedHandler(mtlCmdBuff,this)')
    if '[' in strip_comments(result):raise ValueError('Unadapted Objective-C message remains')
    return result


def strip_comments(source):return re.sub(r'//[^\n]*|/\*.*?\*/','',source,flags=re.S)


PREAMBLE=r'''
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <map>
#include <stdexcept>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>
using VkResult=int32_t;
constexpr VkResult VK_ERROR_OUT_OF_POOL_MEMORY=-1000069000;
struct Context {uint64_t frame=77;uint32_t queueFamily=4,queueIndex=2;};
struct Record {std::string kind;uint64_t session;std::map<std::string,uint64_t> fields;};
struct Control {std::string kind;uint64_t time;};
static Context context;
static uint64_t clockNS=0,currentSession=7,nativeQueries=0,flushCalls=0,destroyed=0;
static bool flushSuccess=true,changeSessionOnDestroy=false,cbDeleted=false;
static std::vector<Record> records;
static std::vector<Control> controls;
static uint64_t mvkStutterMonotonicNS(){return ++clockNS;}
static uint64_t mvkForensicsSessionID(){return currentSession;}
static Context mvkStutterContext(){return context;}
static void require(bool value,const char* message){if(!value)throw std::runtime_error(message);}
static void control(const char* kind){controls.push_back({kind,mvkStutterMonotonicNS()});}
struct MockSubmission;
struct MockCB {uint64_t nativeID=55;MockSubmission* completion=nullptr;};
static uint64_t mvkStutterNativeID(void* raw){++nativeQueries;return raw?static_cast<MockCB*>(raw)->nativeID:0;}
static void mvkForensicsRecordForSession(uint64_t session,const char* kind,std::initializer_list<std::pair<const char*,uint64_t>> fields){
    Record row{kind,session,{}};for(auto item:fields)row.fields[item.first]=item.second;records.push_back(row);controls.push_back({kind,clockNS});
}
static bool mvkForensicsFlushIntent(uint64_t session){require(session!=0,"flush requires saved session");++flushCalls;control("intent-flush");return flushSuccess;}
static void mvkRecordDependencyPhase(void*,const char*){}
static void mvkStutterNativePhase(void*,const char*){}
static void mvkMarkTrackedCommandBufferCommit(void*){control("commit-mark");}
static void mockCommit(void*);
static void mockRelease(void*);
static void mockAddCompletedHandler(void*,MockSubmission*);
'''


SUBMISSION=r'''
struct MockQueue {uint64_t sentinel=0xabc;};
struct MockSubmission {
    uint64_t _stutterSubmissionID=123,_stutterNativeSplit=0;
    MockQueue* _queue=new MockQueue;
    VkResult status=-4;
    explicit MockSubmission(uint64_t count):_stutterNativeSplit(count){}
    ~MockSubmission(){delete _queue;++destroyed;context={999,99,99};if(changeSessionOnDestroy)++currentSession;control("submission-destroy");}
    VkResult getConfigurationResult()const{return status;}
    void finish(){delete this;}
    VkResult normal(void* mtlCmdBuff,bool signalCompletion) {
__NORMAL_TAIL__
    }
    VkResult present(void* mtlCmdBuff) {
__PRESENT_TAIL__
    }
};
static void mockCommit(void* raw){
    if(!raw){control("nil-message-no-op");return;}
    auto* cb=static_cast<MockCB*>(raw);control("actual-commit-enter");
    if(cb->completion)cb->completion->finish();
    control("actual-commit-return");
}
static void mockRelease(void* raw){if(raw){delete static_cast<MockCB*>(raw);cbDeleted=true;control("cb-release");}}
static void mockAddCompletedHandler(void* raw,MockSubmission* submission){static_cast<MockCB*>(raw)->completion=submission;}
static void reset(){context={77,4,2};clockNS=0;currentSession=7;nativeQueries=flushCalls=destroyed=0;flushSuccess=true;changeSessionOnDestroy=false;cbDeleted=false;records.clear();controls.clear();}
static size_t position(const char* kind){for(size_t i=0;i<controls.size();++i)if(controls[i].kind==kind)return i;return controls.size();}
static const Record& endRecord(){require(records.size()==2,"terminal must emit exactly Intent and End");require(records[0].kind=="NativeSubmissionTerminalIntentV1","first record must be Intent");require(records[1].kind=="NativeSubmissionEndV1","second record must be End");return records[1];}
static void emit(const std::string& name){
    std::cout<<"{\"type\":\"case\",\"name\":\""<<name<<"\",\"passed\":true,\"terminalRows\":"<<records.size()<<",\"destroyed\":"<<destroyed<<",\"flushCalls\":"<<flushCalls<<"}\n";
    for(auto& row:records){std::cout<<"{\"type\":\"record\",\"case\":\""<<name<<"\",\"kind\":\""<<row.kind<<"\",\"session\":"<<row.session<<",\"fields\":{";bool first=true;for(auto& item:row.fields){if(!first)std::cout<<',';first=false;std::cout<<'"'<<item.first<<"\":"<<item.second;}std::cout<<"}}\n";}
    std::cout<<"{\"type\":\"controlOrder\",\"case\":\""<<name<<"\",\"events\":[";bool first=true;for(auto& row:controls){if(!first)std::cout<<',';first=false;std::cout<<"{\"kind\":\""<<row.kind<<"\",\"time\":"<<row.time<<'}';}std::cout<<"]}\n";
}
static void checkCommon(const Record& end,uint64_t splits,uint64_t kind,bool hasCB){
    auto& f=end.fields;require(end.session==7,"End must retain original logical session");require(f.at("ownerSubmission")==123&&f.at("ownerFrame")==77,"saved owner numeric identity changed after deletion");
    require(f.at("ownerQueueFamily")==4&&f.at("ownerQueueIndex")==2,"saved queue identity changed after deletion");
    require(f.at("expectedSplitCount")==splits&&f.at("splitCountMeaning")==1,"split count provenance incorrect");require(f.at("submissionKind")==kind,"submission kind incorrect");
    require(f.at("lastNativeCBKnown")==uint64_t(hasCB)&&f.at("lastNativeCB")==uint64_t(hasCB?55:0),"last-CB provenance incorrect");
    require(f.at("intentMachNS")<f.at("intentLoggerEndMachNS"),"intent/flush timing order invalid");require(f.at("intentLoggerWallNS")==f.at("intentLoggerEndMachNS")-f.at("intentMachNS"),"intent wall delta incorrect");
    require(f.at("intentFileFlushSucceeded")==uint64_t(flushSuccess),"flush outcome lost");require(flushCalls==1,"Intent flush must run once");
    require(position("NativeSubmissionTerminalIntentV1")<position("intent-flush"),"flush occurred before Intent");require(position("intent-flush")<position("NativeSubmissionEndV1"),"End occurred before flush");
    if(hasCB){require(f.at("intentLoggerEndMachNS")<f.at("commitStartMachNS"),"commit start precedes Intent/flush completion");require(f.at("commitStartMachNS")<f.at("commitEndMachNS"),"actual commit timestamps reversed");require(f.at("commitEndMachNS")<f.at("endMachNS"),"End precedes commit return");require(f.at("nativeCommitReturned")==1,"commit-return flag missing");
        require(position("intent-flush")<position("actual-commit-enter")&&position("actual-commit-enter")<position("submission-destroy")&&position("submission-destroy")<position("actual-commit-return")&&position("actual-commit-return")<position("NativeSubmissionEndV1"),"Intent/flush -> commit/delete/return -> End event order invalid");}
}
static void runNormal(uint64_t count,bool hasCB,bool completion,bool armed,bool flushOK,bool sessionChange){
    reset();if(!armed)currentSession=0;flushSuccess=flushOK;changeSessionOnDestroy=sessionChange;
    auto* sub=new MockSubmission(count);MockCB* cb=hasCB?new MockCB:nullptr;if(cb&&completion)cb->completion=sub;
    VkResult result=sub->normal(cb,completion);
    bool terminal=completion&&armed;
    if(terminal){const auto& end=endRecord();checkCommon(end,count,1,hasCB);require(end.fields.at("resultBits")==uint32_t(hasCB?-4:VK_ERROR_OUT_OF_POOL_MEMORY),"negative VkResult bits not preserved");require(end.fields.at("endSessionChanged")==uint64_t(sessionChange),"session-change flag wrong");
        if(!hasCB)require(end.fields.at("commitStartMachNS")&&end.fields.at("commitEndMachNS")&&end.fields.at("nativeCommitReturned")==0,"normal nil-message timestamps must not claim a native commit");}
    else {require(records.empty()&&flushCalls==0&&nativeQueries==0,"off/intermediate terminal emits diagnostics");}
    require(result==(hasCB?-4:VK_ERROR_OUT_OF_POOL_MEMORY),"saved return value changed after deletion");require(destroyed==uint64_t(completion),"completion must destroy exactly once");
    emit("normal-splits-"+std::to_string(count)+(hasCB?"-cb":"-nil")+(completion?"-terminal":"-intermediate")+(armed?"-armed":"-off")+(flushOK?"-flush-ok":"-flush-failed")+(sessionChange?"-session-change":""));
    if(!completion)delete sub;if(cb&&!cbDeleted)delete cb;
}
static void runPresent(bool hasCB,bool armed,bool flushOK,bool sessionChange){
    reset();if(!armed)currentSession=0;flushSuccess=flushOK;changeSessionOnDestroy=sessionChange;
    auto* sub=new MockSubmission(100);MockCB* cb=hasCB?new MockCB:nullptr;VkResult result=sub->present(cb);
    if(armed){const auto& end=endRecord();checkCommon(end,hasCB?1:0,2,hasCB);require(end.fields.at("resultBits")==uint32_t(-4),"present saved result bits changed");require(end.fields.at("endSessionChanged")==uint64_t(sessionChange),"present session-change flag wrong");if(!hasCB)require(end.fields.at("commitStartMachNS")==0&&end.fields.at("commitEndMachNS")==0&&end.fields.at("nativeCommitReturned")==0,"present nil branch must not claim commit");}
    else require(records.empty()&&flushCalls==0&&nativeQueries==0,"present off emits diagnostics");
    require(result==-4&&destroyed==1,"present must return saved result after destruction");emit(std::string("present-")+(hasCB?"cb":"nil")+(armed?"-armed":"-off")+(flushOK?"-flush-ok":"-flush-failed")+(sessionChange?"-session-change":""));if(cb)delete cb;
}
int main(){try{
    static_assert(std::is_trivially_copyable<MVKSubmissionTerminalTrace>::value,"terminal must save trivially copied values");
    static_assert(std::is_trivially_destructible<MVKSubmissionTerminalTrace>::value,"terminal destructor must not dereference submission");
    for(uint64_t count:{0ULL,1ULL,2ULL,17ULL,4096ULL})runNormal(count,true,true,true,true,false);
    runNormal(0,false,true,true,true,false);runNormal(3,false,true,true,false,false);
    runNormal(2,true,true,true,false,false);runNormal(2,true,true,true,true,true);
    runNormal(1,true,true,false,true,false);runNormal(0,false,true,false,true,false);
    runNormal(1,true,false,true,true,false);runNormal(7,true,false,false,true,false);
    runPresent(true,true,true,false);runPresent(true,true,false,false);runPresent(true,true,true,true);runPresent(false,true,true,false);runPresent(true,false,true,false);runPresent(false,false,true,false);
    reset();{MVKSubmissionTerminalTrace disabled(false,123,1,nullptr,1,-4);disabled.beginCommit();disabled.endCommit();disabled.finish();require(records.empty()&&flushCalls==0&&nativeQueries==0&&clockNS==0,"disabled struct must be inert");emit("direct-disabled-inert");}
    reset();currentSession=0;{MVKSubmissionTerminalTrace unarmed(true,123,1,nullptr,1,-4);unarmed.beginCommit();unarmed.endCommit();unarmed.finish();require(records.empty()&&flushCalls==0&&nativeQueries==0&&clockNS==0,"unarmed struct must be inert");emit("direct-unarmed-inert");}
    return 0;
}catch(const std::exception& ex){std::cerr<<ex.what()<<'\n';return 1;}}
'''


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',type=Path,default=ROOT/'evidence/submission-terminal-diagnostics-20261026');args=parser.parse_args()
    out=args.output.resolve()
    if not out.is_relative_to(ROOT/'evidence') or out.exists():raise ValueError('New owned evidence directory required')
    out.mkdir(parents=True);source=SOURCE.read_text();source_hash=hashlib.sha256(source.encode()).hexdigest()
    struct=block(source,'struct MVKSubmissionTerminalTrace')+';'
    normal=tail(block(source,'VkResult MVKQueueCommandBufferSubmission::commitActiveMTLCommandBuffer(bool signalCompletion)'))
    present=tail(block(source,'VkResult MVKQueuePresentSurfaceSubmission::execute()'))
    (out/'terminal-original.hpp').write_text(struct+'\n');(out/'normal-tail-original.txt').write_text(normal);(out/'present-tail-original.txt').write_text(present)
    adapted=struct.replace('id<MTLCommandBuffer>','void*')
    if adapted==struct:raise ValueError('Expected one Objective-C type adaptation')
    fixture=PREAMBLE+'\n'+adapted+'\n'+SUBMISSION.replace('__NORMAL_TAIL__',adapt_tail(normal)).replace('__PRESENT_TAIL__',adapt_tail(present,True))
    fixture_path=out/'terminal-exact-source.cpp';fixture_path.write_text(fixture)
    compiler=shutil.which('clang++')
    if not compiler:raise RuntimeError('clang++ unavailable')
    binary=out/'terminal-cpu-asan';compile_command=[compiler,'-std=c++17','-O1','-g','-fsanitize=address,undefined','-fno-omit-frame-pointer','-Wall','-Wextra','-Werror',str(fixture_path),'-o',str(binary)]
    built=subprocess.run(compile_command,capture_output=True,text=True,timeout=60);(out/'compile.stdout.log').write_text(built.stdout);(out/'compile.stderr.log').write_text(built.stderr)
    run=None
    if built.returncode==0:
        run=subprocess.run([str(binary)],capture_output=True,text=True,timeout=30,env=os.environ|{'ASAN_OPTIONS':'abort_on_error=1:detect_stack_use_after_return=1','UBSAN_OPTIONS':'halt_on_error=1:print_stacktrace=1'})
        (out/'run.stdout.jsonl').write_text(run.stdout);(out/'run.stderr.log').write_text(run.stderr)
    rows=[]
    if run:
        for line in run.stdout.splitlines():
            try:rows.append(json.loads(line))
            except ValueError:pass
    cases=[row for row in rows if row.get('type')=='case']
    def audit(text):
        suffix=strip_comments(text.split('[mtlCmdBuff commit]',1)[1]);members=re.findall(r'\bthis\b|\b_[A-Za-z][A-Za-z0-9_]*',suffix)
        return {'postCommitSource':suffix.strip(),'explicitThisOrMemberTokens':members,'noNewPostDestroyMemberDereference':not members,
                'nilFinishGuardReviewed':True,'scope':'Callsite tail only; Objective-C runtime, queue execution and scope destructors are not integration-tested.'}
    unchanged=hashlib.sha256(SOURCE.read_bytes()).hexdigest()==source_hash
    report={'schema':1,'timeUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source':str(SOURCE),'sourceSHA256':source_hash,'sourceUnchangedDuringQualification':unchanged,
            'structAdaptations':['id<MTLCommandBuffer> replaced with void*; all struct statements unchanged'],
            'callsiteAdaptations':['Objective-C string literal prefix removed','commit/release messages replaced by CPU stubs','present completed-handler registration replaced by a CPU callback stub'],
            'compileCommand':compile_command,'compileExitCode':built.returncode,'runExitCode':run.returncode if run else None,'ASanUBSanEnabled':True,'stderrEmpty':bool(run is not None and not run.stderr),
            'cases':cases,'caseCount':len(cases),'normalCallsiteAudit':audit(normal),'presentCallsiteAudit':audit(present),
            'knownSemanticLimit':'Normal nil-CB path retains timestamps around an Objective-C nil-message no-op; lastNativeCBKnown=false and nativeCommitReturned=false correctly avoid claiming a native commit. Present nil-CB path reports commit timestamps0/returned=false. These CPU stubs do not validate Metal runtime behavior.',
            'actualGameTested':False,'actualGPUWorkExecuted':False,'MetalRuntimeLoaded':False,'NativeSourceModified':False,
            'passed':built.returncode==0 and run is not None and run.returncode==0 and not run.stderr and len(cases)==21 and unchanged and not audit(normal)['explicitThisOrMemberTokens'] and not audit(present)['explicitThisOrMemberTokens']}
    (out/'qualification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'output':str(out),'passed':report['passed'],'cases':len(cases),'compileExitCode':built.returncode,'runExitCode':report['runExitCode']}))
    raise SystemExit(0 if report['passed'] else 1)


if __name__=='__main__':main()
