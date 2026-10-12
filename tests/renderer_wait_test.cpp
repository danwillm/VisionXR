#include "renderer_wait.hpp"
#include <cstdio>
#include <cstdlib>
#define CHECK(x) do { if (!(x)) std::abort(); } while (0)
int main() {
    using backend::RendererState;
    auto state = RendererState::Paused;
    unsigned waits = 0;
    auto read = [&] { return state; };
    auto resume = [&] { ++waits; state = RendererState::Running; };
    CHECK(backend::waitForRunning(read, resume)); CHECK(waits == 1);
    CHECK(backend::waitForRunning(read, resume)); CHECK(waits == 1);
    state = RendererState::Paused; // A later pause must resume without ending the session.
    CHECK(backend::waitForRunning(read, resume)); CHECK(waits == 2);
    state = RendererState::Invalidated;
    CHECK(!backend::waitForRunning(read, resume)); CHECK(waits == 2);
    state = RendererState::Paused;
    CHECK(!backend::waitForRunning(read, [&] { ++waits; state = RendererState::Invalidated; }));
    CHECK(waits == 3); // Closing the immersive space while paused must end the loop.
    std::puts("Renderer startup, pause/resume, and invalidation: OK");
}
