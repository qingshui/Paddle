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

#include "paddle/fluid/operators/batch_fc_op.h"
#include <string>

namespace paddle {
namespace operators {

class BatchFCOp : public framework::OperatorWithKernel {
 public:
  using framework::OperatorWithKernel::OperatorWithKernel;

  void InferShape(framework::InferShapeContext* ctx) const override {
    OP_INOUT_CHECK(ctx->HasInput("Input"), "Input", "Input", "BatchFCOp");
    OP_INOUT_CHECK(ctx->HasInput("W"), "Input", "W", "BatchFCOp");
    OP_INOUT_CHECK(ctx->HasInput("Bias"), "Input", "Bias", "BatchFCOp");
    OP_INOUT_CHECK(ctx->HasOutput("Out"), "Output", "Out", "BatchFCOp");

    auto input_dims = ctx->GetInputDim("Input");
    auto w_dims = ctx->GetInputDim("W");
    auto batchcount = ctx->Attrs().Get<int64_t>("batchcount");

    int feature_dim = input_dims[1] / batchcount;
    PADDLE_ENFORCE_EQ(feature_dim, w_dims[0],
                      platform::errors::InvalidArgument(
                          "Input.dim[1]/batchcount and W.dim[0] of BatchFCOp "
                          "should be same."));

    auto bias_dims = ctx->GetInputDim("Bias");
    PADDLE_ENFORCE_EQ(bias_dims[1], w_dims[1],
                      platform::errors::InvalidArgument(
                          "Bias.dim[1] should be same as W.dim[1]."));

    ctx->SetOutputDim("Out", {input_dims[0], w_dims[1]});
    ctx->ShareLoD("Input", /*->*/ "Out");
  }

 protected:
  framework::OpKernelType GetExpectedKernelType(
      const framework::ExecutionContext& ctx) const override {
    return framework::OpKernelType(
        OperatorWithKernel::IndicateVarDataType(ctx, "Input"),
        ctx.device_context());
  }
};

class BatchFCGradOp : public framework::OperatorWithKernel {
 public:
  using framework::OperatorWithKernel::OperatorWithKernel;

  void InferShape(framework::InferShapeContext* ctx) const override {
    PADDLE_ENFORCE_EQ(
        ctx->HasInput("Input"), true,
        platform::errors::InvalidArgument("Input should not be null"));
    PADDLE_ENFORCE_EQ(
        ctx->HasInput("W"), true,
        platform::errors::InvalidArgument("Input(W) should not be null"));

    ctx->SetOutputDim(framework::GradVarName("Input"),
                      ctx->GetInputDim("Input"));
    ctx->SetOutputDim(framework::GradVarName("W"), ctx->GetInputDim("W"));
    ctx->SetOutputDim(framework::GradVarName("Bias"), ctx->GetInputDim("Bias"));
  }

 protected:
  framework::OpKernelType GetExpectedKernelType(
      const framework::ExecutionContext& ctx) const override {
    return framework::OpKernelType(OperatorWithKernel::IndicateVarDataType(
                                       ctx, framework::GradVarName("Out")),
                                   ctx.device_context());
  }
};

class BatchFCOpMaker : public framework::OpProtoAndCheckerMaker {
 public:
  void Make() override {
    AddInput("Input", "(Tensor) Input tensor of batch_fc_op operator.");
    AddInput("W", "(Tensor) Input tensor of batch_fc_op operator.");
    AddInput("Bias", "(Tensor) Input tensor of batch_fc_op operator.");
    AddAttr<int64_t>("batchcount", "(int64_t) the batchcount");
    AddOutput("Out", "Output tensor of batch_fc_op operator.");
    AddComment(R"DOC(
BatchFC Operator.
Notice: It currently supports GPU device.
This Op exists in contrib, which means that it is not shown to the public.
)DOC");
  }
};

template <typename T>
class BatchFCGradOpMaker : public framework::SingleGradOpMaker<T> {
 public:
  using framework::SingleGradOpMaker<T>::SingleGradOpMaker;

 protected:
  void Apply(GradOpPtr<T> op) const override {
    op->SetType("batch_fc_grad");

    op->SetInput("Input", this->Input("Input"));
    op->SetInput("W", this->Input("W"));
    op->SetInput("Bias", this->Input("Bias"));
    op->SetInput(framework::GradVarName("Out"), this->OutputGrad("Out"));

    op->SetOutput(framework::GradVarName("Input"), this->InputGrad("Input"));
    op->SetOutput(framework::GradVarName("W"), this->InputGrad("W"));
    op->SetOutput(framework::GradVarName("Bias"), this->InputGrad("Bias"));
    op->SetAttrMap(this->Attrs());
  }
};

}  // namespace operators
}  // namespace paddle

namespace ops = paddle::operators;
REGISTER_OPERATOR(batch_fc, ops::BatchFCOp, ops::BatchFCOpMaker,
                  ops::BatchFCGradOpMaker<paddle::framework::OpDesc>,
                  ops::BatchFCGradOpMaker<paddle::imperative::OpBase>);

REGISTER_OPERATOR(batch_fc_grad, ops::BatchFCGradOp);

REGISTER_OP_CPU_KERNEL(
    batch_fc, ops::BatchFCKernel<paddle::platform::CPUDeviceContext, float>,
    ops::BatchFCKernel<paddle::platform::CPUDeviceContext, double>);
