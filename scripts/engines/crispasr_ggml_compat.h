// Two ops Nemotron's graph calls that exist only in CrispASR's own ggml fork,
// rebuilt here from ops whisper.cpp's ggml has, so the app still carries one
// ggml. Force-included into nemotron.cpp by CMakeLists.txt; nothing else sees
// them. The fork fuses each into one kernel — these are the same arithmetic
// in two or three, slower by a hair and equal in output.
#pragma once
#include "ggml.h"

// LayerNorm with its affine: norm(x) * w + b, either of w and b optional.
static inline struct ggml_tensor* ggml_norm_affine(struct ggml_context* ctx, struct ggml_tensor* x,
                                                   struct ggml_tensor* w, struct ggml_tensor* b, float eps) {
    struct ggml_tensor* y = ggml_norm(ctx, x, eps);
    if (w)
        y = ggml_mul(ctx, y, w);
    if (b)
        y = ggml_add(ctx, y, b);
    return y;
}

// The Conformer's GLU: split the rows in half, first half × sigmoid(second).
// "Swapped" because ggml's own GLUs put the activation on the first half.
static inline struct ggml_tensor* ggml_siglu_swapped(struct ggml_context* ctx, struct ggml_tensor* x) {
    const int64_t h = x->ne[0] / 2;
    struct ggml_tensor* a =
        ggml_view_4d(ctx, x, h, x->ne[1], x->ne[2], x->ne[3], x->nb[1], x->nb[2], x->nb[3], 0);
    struct ggml_tensor* g =
        ggml_view_4d(ctx, x, h, x->ne[1], x->ne[2], x->ne[3], x->nb[1], x->nb[2], x->nb[3], h * ggml_element_size(x));
    return ggml_mul(ctx, ggml_cont(ctx, a), ggml_sigmoid(ctx, ggml_cont(ctx, g)));
}

// Stock ggml_conv_2d_dw lays its im2col out in F16 whatever the kernel is, so
// Nemotron's F32 depthwise kernels become an F32 × F16 matmul that neither
// Metal nor the CPU backend has a kernel for. The fork keeps im2col in the
// kernel's own type; so does this, and nemotron.cpp's calls land here.
static inline struct ggml_tensor* sayctrl_conv_2d_dw(struct ggml_context* ctx, struct ggml_tensor* a,
                                                     struct ggml_tensor* b, int s0, int s1, int p0, int p1, int d0,
                                                     int d1) {
    struct ggml_tensor* new_a = ggml_reshape_4d(ctx, a, a->ne[0], a->ne[1], 1, a->ne[2] * a->ne[3]);
    struct ggml_tensor* im2col =
        ggml_im2col(ctx, new_a, ggml_reshape_4d(ctx, b, b->ne[0], b->ne[1], 1, b->ne[2] * b->ne[3]), s0, s1, p0, p1,
                    d0, d1, true, a->type == GGML_TYPE_F16 ? GGML_TYPE_F16 : GGML_TYPE_F32);
    struct ggml_tensor* new_b =
        ggml_reshape_4d(ctx, im2col, im2col->ne[0], im2col->ne[2] * im2col->ne[1], b->ne[2], b->ne[3]);
    new_a = ggml_reshape_4d(ctx, new_a, new_a->ne[0] * new_a->ne[1], new_a->ne[2], new_a->ne[3], 1);
    struct ggml_tensor* result = ggml_mul_mat(ctx, new_a, new_b);
    return ggml_reshape_4d(ctx, result, im2col->ne[1], im2col->ne[2], b->ne[2], b->ne[3]);
}
#define ggml_conv_2d_dw sayctrl_conv_2d_dw
