#include "App.h"

#include <sched.h>

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

// Worker count must come from the CPUs this container may actually run on.
// std::thread::hardware_concurrency() reports the HOST's CPU count (it reads
// _SC_NPROCESSORS_ONLN, which knows nothing about cgroups or cpuset), so under
// a 2-CPU limit on a 16-CPU host it would spawn 16 event loops fighting over 2
// CPUs. sched_getaffinity is what every other contender's runtime ends up
// consulting, so using it here puts uws on the same footing.
static unsigned int workerCount() {
    if (const char *env = std::getenv("UWS_THREADS")) {
        const int n = std::atoi(env);
        if (n > 0) {
            return static_cast<unsigned int>(n);
        }
    }

    cpu_set_t set;
    CPU_ZERO(&set);
    if (sched_getaffinity(0, sizeof(set), &set) == 0) {
        const int n = CPU_COUNT(&set);
        if (n > 0) {
            return static_cast<unsigned int>(n);
        }
    }

    const unsigned int n = std::thread::hardware_concurrency();
    return n ? n : 1u;
}

int main() {
    std::string jsonLarge;
    {
        std::ifstream in("large.json", std::ios::binary);
        if (!in) {
            return 1;
        }
        std::ostringstream ss;
        ss << in.rdbuf();
        jsonLarge = ss.str();
    }

    // One App (and one event loop) per worker, each listening on the same port.
    // uSockets sets SO_REUSEPORT, so the kernel load-balances accepts across
    // them. jsonLarge outlives every thread and is only read, so sharing a
    // const reference across loops is safe.
    const unsigned int workers = workerCount();
    std::vector<std::thread> threads;
    threads.reserve(workers);

    for (unsigned int i = 0; i < workers; i++) {
        threads.emplace_back([&jsonLarge]() {
            uWS::App()
                .get("/plaintext", [](auto *res, auto * /*req*/) {
                    res->writeHeader("Content-Type", "text/plain")
                       ->end("Hello, World!");
                })
                .get("/json", [](auto *res, auto * /*req*/) {
                    res->writeHeader("Content-Type", "application/json")
                       ->end("{\"message\":\"Hello, World!\"}");
                })
                .get("/json-large", [&jsonLarge](auto *res, auto * /*req*/) {
                    res->writeHeader("Content-Type", "application/json")
                       ->end(std::string_view(jsonLarge));
                })
                .listen("0.0.0.0", 8080, [](auto *listen_socket) {
                    if (!listen_socket) {
                        exit(1);
                    }
                })
                .run();
        });
    }

    for (std::thread &t : threads) {
        t.join();
    }

    return 0;
}
