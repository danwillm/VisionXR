#pragma once
#include <openxr/openxr.h>
#include <cmath>

namespace pose {
constexpr XrPosef identity() { return {{0, 0, 0, 1}, {0, 0, 0}}; }
inline XrQuaternionf multiply(XrQuaternionf a, XrQuaternionf b) {
    return {a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
            a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
            a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
            a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z};
}
inline XrVector3f rotate(XrQuaternionf q, XrVector3f v) {
    auto r = multiply(multiply(q, {v.x, v.y, v.z, 0}), {-q.x, -q.y, -q.z, q.w});
    return {r.x, r.y, r.z};
}
inline XrPosef compose(XrPosef a, XrPosef b) {
    auto p = rotate(a.orientation, b.position);
    return {multiply(a.orientation, b.orientation),
            {a.position.x+p.x, a.position.y+p.y, a.position.z+p.z}};
}
inline XrPosef inverse(XrPosef p) {
    XrQuaternionf q{-p.orientation.x, -p.orientation.y, -p.orientation.z, p.orientation.w};
    return {q, rotate(q, {-p.position.x, -p.position.y, -p.position.z})};
}
inline bool valid(XrPosef p) {
    auto q = p.orientation;
    float norm = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w;
    return std::isfinite(norm) && std::abs(norm - 1.f) < 0.01f &&
           std::isfinite(p.position.x) && std::isfinite(p.position.y) && std::isfinite(p.position.z);
}
inline XrPosef localOrigin(XrPosef head) {
    auto forward = rotate(head.orientation, {0, 0, -1});
    float yaw = (forward.x*forward.x + forward.z*forward.z > 1e-6f)
                    ? std::atan2(-forward.x, -forward.z) : 0.f;
    return {{0, std::sin(yaw/2), 0, std::cos(yaw/2)}, head.position};
}
}
