// Copyright Supranational LLC
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#ifndef __NTT_KERNELS_CU__
#define __NTT_KERNELS_CU__

#include <cooperative_groups.h>

__device__ __forceinline__
index_t bit_rev(index_t i, unsigned int nbits)
{
    if (sizeof(i) == 4 || nbits <= 32)
        return __brev(i) >> (8*sizeof(unsigned int) - nbits);
    else
        return __brevll(i) >> (8*sizeof(unsigned long long) - nbits);
}

#ifdef __CUDA_ARCH__
__device__ __forceinline__
void shfl_bfly(fr_t& r, int laneMask)
{
    #pragma unroll
    for (int iter = 0; iter < r.len(); iter++)
        r[iter] = __shfl_xor_sync(0xFFFFFFFF, r[iter], laneMask);
}
#endif

__device__ __forceinline__
void shfl_bfly(index_t& index, int laneMask)
{
    index = __shfl_xor_sync(0xFFFFFFFF, index, laneMask);
}

template<typename T>
__device__ __forceinline__
void swap(T& u1, T& u2)
{
    T temp = u1;
    u1 = u2;
    u2 = temp;
}

// Permutes the data in an array such that data[i] = data[bit_reverse(i)]
// and data[bit_reverse(i)] = data[i]
__launch_bounds__(1024) __global__
void bit_rev_permutation(fr_t* d_out, const fr_t *d_in, uint32_t lg_domain_size)
{
    index_t i = threadIdx.x + blockDim.x * (index_t)blockIdx.x;
    index_t r = bit_rev(i, lg_domain_size);

    if (i < r || (d_out != d_in && i == r)) {
        fr_t t0 = d_in[i];
        fr_t t1 = d_in[r];
        d_out[r] = t0;
        d_out[i] = t1;
    }
}

template<typename T>
static __device__ __host__ constexpr uint32_t lg2(T n)
{   uint32_t ret=0; while (n>>=1) ret++; return ret;   }

__global__
void bit_rev_permutation_aux(fr_t* out, const fr_t* in, uint32_t lg_domain_size)
{
    const size_t Z_COUNT = 256 / sizeof(fr_t);
    const uint32_t LG_Z_COUNT = lg2(Z_COUNT);

    extern __shared__ fr_t exchange[];
    fr_t (*xchg)[Z_COUNT][Z_COUNT] = reinterpret_cast<decltype(xchg)>(exchange);

    index_t step = (index_t)1 << (lg_domain_size - LG_Z_COUNT);
    index_t group_idx = (threadIdx.x + blockDim.x * (index_t)blockIdx.x) >> LG_Z_COUNT;
    uint32_t brev_limit = lg_domain_size - LG_Z_COUNT * 2;
    index_t brev_mask = ((index_t)1 << brev_limit) - 1;
    index_t group_idx_brev =
        (group_idx & ~brev_mask) | bit_rev(group_idx & brev_mask, brev_limit);
    uint32_t group_thread = threadIdx.x & (Z_COUNT - 1);
    uint32_t group_thread_rev = bit_rev(group_thread, LG_Z_COUNT);
    uint32_t group_in_block_idx = threadIdx.x >> LG_Z_COUNT;

    #pragma unroll
    for (uint32_t i = 0; i < Z_COUNT; i++) {
        xchg[group_in_block_idx][i][group_thread_rev] =
            in[group_idx * Z_COUNT + i * step + group_thread];
    }

    if (Z_COUNT > WARP_SZ)
        __syncthreads();
    else
        __syncwarp();

    #pragma unroll
    for (uint32_t i = 0; i < Z_COUNT; i++) {
        out[group_idx_brev * Z_COUNT + i * step + group_thread] =
            xchg[group_in_block_idx][group_thread_rev][i];
    }
}

__device__ __forceinline__
fr_t get_intermediate_root(index_t pow, const fr_t (*roots)[WINDOW_SIZE],
                           unsigned int nbits = MAX_LG_DOMAIN_SIZE)
{
    unsigned int off = 0;

    fr_t root = roots[off][pow % WINDOW_SIZE];
    #pragma unroll 1
    while (pow >>= LG_WINDOW_SIZE)
        root *= roots[++off][pow % WINDOW_SIZE];

    return root;
}

__launch_bounds__(1024) __global__
void LDE_distribute_powers(fr_t* d_inout, uint32_t lg_blowup, bool bitrev,
                           const fr_t (*gen_powers)[WINDOW_SIZE],
                           bool ext_pow = false)
{
    index_t idx = threadIdx.x + blockDim.x * (index_t)blockIdx.x;
    index_t pow = idx;
    fr_t r = d_inout[idx];

    if (bitrev) {
        size_t domain_size = gridDim.x * (size_t)blockDim.x;
        assert((domain_size & (domain_size-1)) == 0);
        uint32_t lg_domain_size = 63 - __clzll(domain_size);

        pow = bit_rev(idx, lg_domain_size);
    }

    if (ext_pow)
        pow <<= lg_blowup;

    r = r * get_intermediate_root(pow, gen_powers);

    d_inout[idx] = r;
}

__launch_bounds__(1024) __global__
void LDE_spread_distribute_powers(fr_t* out, fr_t* in,
                                  const fr_t (*gen_powers)[WINDOW_SIZE],
                                  uint32_t lg_domain_size, uint32_t lg_blowup,
                                  bool perform_shift = true,
                                  bool ext_pow = false)
{
    extern __shared__ fr_t exchange[]; // block size

    size_t domain_size = (size_t)1 << lg_domain_size;
    uint32_t blowup = 1u << lg_blowup;
    uint32_t stride = gridDim.x * blockDim.x;

    assert(lg_domain_size + lg_blowup <= MAX_LG_DOMAIN_SIZE &&
           (stride & (stride-1)) == 0);

    bool overlapping_data = false;

    if ((in < out && (in + domain_size) > out)
     || (in >= out && (out + domain_size * blowup) > in))
    {
        overlapping_data = true;
        assert(&out[domain_size * (blowup - 1)] == &in[0]);
    }

    index_t idx0 = blockDim.x * blockIdx.x;
    uint32_t thread_pos = threadIdx.x & (blowup - 1);

#if 0
    index_t iters = domain_size / stride;
#else
    index_t iters = domain_size >> (31 - __clz(stride));
#endif

    for (index_t iter = 0; iter < iters; iter++) {
        index_t idx = idx0 + threadIdx.x;

        fr_t r = in[idx];

        if (perform_shift) {
            index_t pow = bit_rev(idx, lg_domain_size +
                                  (ext_pow ? lg_blowup : 0));

            r = r * get_intermediate_root(pow, gen_powers);
        }

        __syncthreads();

        exchange[threadIdx.x] = r;

        if (overlapping_data && (iter >= (blowup - 1) * (iters >> lg_blowup)))
            cooperative_groups::this_grid().sync();
        else
            __syncthreads();

        r.zero();

        for (uint32_t i = 0; i < blowup; i++) {
            uint32_t offset = i * blockDim.x + threadIdx.x;

            if (thread_pos == 0)
                r = exchange[offset >> lg_blowup];

            out[(idx0 << lg_blowup) + offset] = r;
        }

        idx0 += stride;
    }
}

__device__ __forceinline__
void get_intermediate_roots(fr_t& root0, fr_t& root1,
                            index_t idx0, index_t idx1,
                            const fr_t (*roots)[WINDOW_SIZE])
{
    int win = (WINDOW_NUM - 1) * LG_WINDOW_SIZE;
    int off = (WINDOW_NUM - 1);

    root0 = roots[off][idx0 >> win];
    root1 = roots[off][idx1 >> win];
    #pragma unroll 1
    while (off--) {
        win -= LG_WINDOW_SIZE;
        root0 *= roots[off][(idx0 >> win) % WINDOW_SIZE];
        root1 *= roots[off][(idx1 >> win) % WINDOW_SIZE];
    }
}

#if defined(FEATURE_BABY_BEAR) || defined(FEATURE_GOLDILOCKS)
# include "kernels/gs_mixed_radix_narrow.cu"
# include "kernels/ct_mixed_radix_narrow.cu"
#else // 256-bit fields
# include "kernels/gs_mixed_radix_wide.cu"
# include "kernels/ct_mixed_radix_wide.cu"
#endif

#endif /* __NTT_KERNELS_CU__ */
