#include "R2Native.h"
#include <fstream>
#include <iostream>
int main(int argc,char**argv){
 if(argc!=3)return 3;std::ifstream f(argv[1],std::ios::binary|std::ios::ate);if(!f)return 4;size_t n=size_t(f.tellg());f.seekg(0);std::vector<uint32_t> input(n/4);f.read((char*)input.data(),n);R2NativeResult out;std::string error;
 if(!r2NativeLower(input,{{{0,0},3},{{0,8},3}},out,error)){std::cerr<<error<<"\n";return 1;}
 std::ofstream bin(argv[2],std::ios::binary);bin.write((char*)out.binary.data(),out.binary.size()*4);std::ofstream text(std::string(argv[2])+".txt");text<<out.assembly;
 std::cout<<"slots="<<out.slots<<" guarded="<<out.guardedOperations<<" physicalCallerManaged="<<out.physicalAccesses<<"\n";return 0;
}
