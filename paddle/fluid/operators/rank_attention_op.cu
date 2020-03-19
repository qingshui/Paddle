/* Copyright (c) 2020 PaddlePaddle Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License. */

#include <cublas.h>
#include "paddle/fluid/framework/eigen.h"
#include "paddle/fluid/operators/math/blas.h"
#include "paddle/fluid/operators/rank_attention.cu.h"
#include "paddle/fluid/operators/rank_attention_op.h"
#include "paddle/fluid/platform/cuda_primitives.h"
#include "paddle/fluid/platform/gpu_info.h"

namespace paddle {
namespace operators {

using framework::Tensor;

template <typename DeviceContext, typename T>
class RankAttentionCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    auto *X = ctx.Input<Tensor>("X");
    auto *rank_offset = ctx.Input<Tensor>("RankOffset");
    auto *param = ctx.Input<Tensor>("RankParam");
    int max_rank = ctx.Attr<int>("MaxRank");
    auto *Out = ctx.Output<Tensor>("Out");

    // check dims
    auto x_dims = X->dims();
    auto ins_num = x_dims[0];
    auto x_fea_dim = x_dims[1];
    auto para_dims = param->dims();
    auto para_row = para_dims[0];
    auto para_col = para_dims[1];
    auto rank_offset_dims = rank_offset->dims();
    PADDLE_ENFORCE_EQ(
        rank_offset_dims[0], ins_num,
        platform::errors::InvalidArgument("Input(RankOffset) has wrong rows."));
    PADDLE_ENFORCE_EQ((rank_offset_dims[1] - 1) / 2, max_rank,
                      platform::errors::InvalidArgument(
                          "Input(RankOffset) has wrong columns."));
    PADDLE_ENFORCE_EQ(
        max_rank * max_rank * x_fea_dim, para_row,
        platform::errors::InvalidArgument("Input(RankParam) has wrong rows."));

    int block_matrix_row = max_rank * x_fea_dim;

    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();

    T *param_help_data;
    cudaMalloc(reinterpret_cast<void **>(&param_help_data),
               ins_num * block_matrix_row * para_col * sizeof(T));
    cudaMemset(param_help_data, 0,
               ins_num * block_matrix_row * para_col * sizeof(T));

    T *input_help_data;
    cudaMalloc(reinterpret_cast<void **>(&input_help_data),
               ins_num * block_matrix_row * sizeof(T));
    cudaMemset(input_help_data, 0, ins_num * block_matrix_row * sizeof(T));

    T *ins_rank_data;
    cudaMalloc(reinterpret_cast<void **>(&ins_rank_data), ins_num * sizeof(T));
    cudaMemset(ins_rank_data, -1, ins_num * sizeof(T));

    Out->mutable_data<T>(ctx.GetPlace());

    // initialize
    auto out_eigen = framework::EigenVector<T>::Flatten(*Out);

    auto &place = *ctx.template device_context<platform::CUDADeviceContext>()
                       .eigen_device();

    out_eigen.device(place) = out_eigen.constant(static_cast<T>(0));

    // get data ptr
    T *out_data = Out->data<T>();
    expand_rank_attention_input(
        ctx.cuda_device_context().stream(), X->data<T>(), ins_num, x_fea_dim,
        input_help_data, ins_num, block_matrix_row, rank_offset->data<int>(),
        rank_offset_dims[0], rank_offset_dims[1], ins_rank_data, max_rank);

    expand_rank_attention_param(
        ctx.cuda_device_context().stream(), X->data<T>(), ins_num, x_fea_dim,
        rank_offset->data<int>(), rank_offset_dims[0], rank_offset_dims[1],
        param->data<T>(), para_row, para_col, param_help_data,
        ins_num * block_matrix_row, para_col, max_rank);

    CBLAS_TRANSPOSE transA = CblasNoTrans;
    CBLAS_TRANSPOSE transB = CblasNoTrans;

    T alpha = 1;
    T beta = 0;
    int64_t strideA = block_matrix_row;
    int64_t strideB = block_matrix_row * para_col;

    auto blas = math::GetBlas<platform::CUDADeviceContext, T>(dev_ctx);
    blas.BatchedGEMM(transA, transB, 1, para_col, block_matrix_row, alpha,
                     input_help_data, param_help_data, beta, out_data, ins_num,
                     strideA, strideB);

    cudaFree(param_help_data);
    cudaFree(input_help_data);
    cudaFree(ins_rank_data);
  }
};

template <typename DeviceContext, typename T>
class RankAttentionGradOpCUDAKernel : public framework::OpKernel<T> {
 public:
  void Compute(const framework::ExecutionContext &ctx) const override {
    auto *X = ctx.Input<Tensor>("X");
    auto *rank_offset = ctx.Input<Tensor>("RankOffset");
    auto *param = ctx.Input<Tensor>("RankParam");
    auto *dout = ctx.Input<Tensor>(framework::GradVarName("Out"));

    auto *drank_para = ctx.Output<Tensor>(framework::GradVarName("RankParam"));

    // get dim
    auto x_dims = X->dims();
    auto ins_num = x_dims[0];
    auto x_fea_dim = x_dims[1];
    auto para_dims = param->dims();
    auto para_row = para_dims[0];
    auto para_col = para_dims[1];
    auto rank_offset_dims = rank_offset->dims();
    auto max_rank = (rank_offset_dims[1] - 1) / 2;
    int block_matrix_row = max_rank * x_fea_dim;
    auto &dev_ctx = ctx.template device_context<platform::CUDADeviceContext>();
    auto &place = *ctx.template device_context<platform::CUDADeviceContext>()
                       .eigen_device();

    // initialize out grad
    drank_para->mutable_data<T>(ctx.GetPlace());
    auto drank_para_eigen = framework::EigenVector<T>::Flatten(*drank_para);
    drank_para_eigen.device(place) =
        drank_para_eigen.constant(static_cast<T>(0));

    T *input_help_data;
    T *ins_rank_data;
    T *param_grad_data;

    cudaMalloc(reinterpret_cast<void **>(&input_help_data),
               ins_num * block_matrix_row * sizeof(T));
    cudaMalloc(reinterpret_cast<void **>(&ins_rank_data), ins_num * sizeof(T));
    cudaMalloc(reinterpret_cast<void **>(&param_grad_data),
               ins_num * block_matrix_row * para_col * sizeof(T));

    cudaMemset(input_help_data, 0, ins_num * block_matrix_row * sizeof(T));
    cudaMemset(ins_rank_data, -1, ins_num * sizeof(T));
    cudaMemset(param_grad_data, 0,
               ins_num * block_matrix_row * para_col * sizeof(T));

    // expand input
    expand_rank_attention_input(
        ctx.cuda_device_context().stream(), X->data<T>(), ins_num, x_fea_dim,
        input_help_data, ins_num, block_matrix_row, rank_offset->data<int>(),
        rank_offset_dims[0], rank_offset_dims[1], ins_rank_data, max_rank);

    auto blas = math::GetBlas<platform::CUDADeviceContext, T>(dev_ctx);
    T alpha = 1;
    T beta = 0;

    // get param_grad
    CBLAS_TRANSPOSE transA = CblasTrans;
    CBLAS_TRANSPOSE transB = CblasNoTrans;
    int64_t strideA = block_matrix_row;
    int64_t strideB = para_col;

    blas.BatchedGEMM(transA, transB, block_matrix_row, para_col, 1, alpha,
                     input_help_data, dout->data<T>(), beta, param_grad_data,
                     ins_num, strideA, strideB);

    // merge param_grad to get drank_para
    merge_rank_attention_param_grad(
        ctx.cuda_device_context().stream(), param_grad_data,
        ins_num * block_matrix_row, para_col, drank_para->data<T>(), para_row,
        para_col, ins_rank_data, ins_num, max_rank, x_fea_dim);

    cudaFree(input_help_data);
    cudaFree(ins_rank_data);
    cudaFree(param_grad_data);
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
using GPUCtx = paddle::platform::CUDADeviceContext;
REGISTER_OP_CUDA_KERNEL(rank_attention,
                        ops::RankAttentionCUDAKernel<GPUCtx, float>,
                        ops::RankAttentionCUDAKernel<GPUCtx, double>);

REGISTER_OP_CUDA_KERNEL(rank_attention_grad,
                        ops::RankAttentionGradOpCUDAKernel<GPUCtx, float>,
                        ops::RankAttentionGradOpCUDAKernel<GPUCtx, double>);