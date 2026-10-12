#pragma once

namespace backend {
enum class RendererState { Paused, Running, Invalidated };
template<class State, class Wait>
bool waitForRunning(State state, Wait wait) {
    for (;;) {
        switch (state()) {
            case RendererState::Running: return true;
            case RendererState::Invalidated: return false;
            case RendererState::Paused: wait(); break;
        }
    }
}
}
