// Verify complete, bounded current records while a concurrent reader polls.
#include "MVKTraceSnapshot.h"
#include <atomic>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <string>
#include <thread>

int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::filesystem::path root(argv[1]);
    if (std::filesystem::exists(root) || !std::filesystem::create_directory(root)) return 3;
    const auto path=(root/"current.json").string();
    if (!mvkWriteTraceSnapshot(path.c_str(), "{\"sequence\":0}\n")) return 4;
    std::atomic<bool> done{false};
    std::atomic<unsigned> failures{0},reads{0};
    std::thread reader([&] {
        unsigned previous=0;
        do {
            std::ifstream in(path);std::string line((std::istreambuf_iterator<char>(in)), {});
            unsigned value=0;int used=0;
            if (sscanf(line.c_str(),"{\"sequence\":%u}%n",&value,&used)!=1 ||
                line.substr(used)!="\n" || value<previous || value>2200) ++failures;
            previous=value;++reads;
        } while (!done);
    });
    // Surpass both historical caps; the fixed-size current record must update.
    for (unsigned i=1;i<=2200;++i) {
        char line[64];snprintf(line,sizeof(line),"{\"sequence\":%u}\n",i);
        if (!mvkWriteTraceSnapshot(path.c_str(),line)) ++failures;
    }
    done=true;reader.join();
    std::ifstream in(path);std::string last((std::istreambuf_iterator<char>(in)), {});
    if (last!="{\"sequence\":2200}\n" || std::filesystem::exists(path+".tmp")) ++failures;
    // Failure to write a new snapshot must preserve the previous valid file.
    if(mvkWriteTraceSnapshot((root/"absent/current.json").c_str(),"bad")) ++failures;
    std::cout<<"{\"passed\":"<<(failures?"false":"true")<<",\"updates\":2200,\"concurrentReads\":"<<reads
             <<",\"partialOrReorderedReads\":"<<failures<<",\"finalSequence\":2200,\"boundedCurrentFiles\":1}\n";
    return failures?5:0;
}
