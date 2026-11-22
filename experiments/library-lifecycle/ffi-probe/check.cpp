#include "catalog_probe.h"
#include <iostream>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    if (rm_probe_count_v1(nullptr, 0) != -1) return 3;
    for (int rating : {0, 4}) {
        const auto count = rm_probe_count_v1(argv[1], rating);
        if (count < 0) return 4;
        std::cout << count << '\n';
    }
}
