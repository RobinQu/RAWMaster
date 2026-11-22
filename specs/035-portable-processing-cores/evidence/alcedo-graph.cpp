// Compile this driver with the pinned AlcedoStudio pipeline_graph.cpp.
// Only the node fixtures live here. The graph, sorter and validators are upstream.
#include <algorithm>
#include <iostream>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "edit/graph/pipeline_graph.hpp"
#include "edit/operators/models/builtin_type_ids.hpp"

namespace {
using namespace alcedo;

class NodeFixture final : public INodeModel {
 public:
  NodeFixture(std::string name, OperatorTypeId type)
      : id_(std::move(name)), type_(std::move(type)) {
    if (type_ != type_ids::DevelopNode()) {
      inputs_.push_back({PortId{"image"}, PortDataType::SceneImage, true});
    }
    if (type_ != type_ids::DrtNode()) {
      outputs_.push_back({PortId{"image"}, PortDataType::SceneImage, true});
    }
  }

  const NodeId& Id() const override { return id_; }
  const OperatorTypeId& Type() const override { return type_; }
  std::string_view DisplayName() const override { return id_.Value(); }
  std::span<const PortDescriptor> InputPorts() const override { return inputs_; }
  std::span<const PortDescriptor> OutputPorts() const override { return outputs_; }
  nlohmann::json ToJson() const override { return id_.Value(); }
  std::shared_ptr<INodeModel> Clone() const override { return std::make_shared<NodeFixture>(*this); }

 private:
  NodeId id_;
  OperatorTypeId type_;
  std::vector<PortDescriptor> inputs_;
  std::vector<PortDescriptor> outputs_;
};
}  // namespace

int main() {
  using namespace alcedo;
  PipelineGraph graph;
  graph.AddNode(std::make_unique<NodeFixture>("display", type_ids::DrtNode()));
  graph.AddNode(std::make_unique<NodeFixture>("grade", type_ids::ColorGradeNode()));
  graph.AddNode(std::make_unique<NodeFixture>("input", type_ids::DevelopNode()));
  graph.Connect(NodeId{"input"}, PortId{"image"}, NodeId{"grade"}, PortId{"image"});
  graph.Connect(NodeId{"grade"}, PortId{"image"}, NodeId{"display"}, PortId{"image"});
  const std::vector<NodeId> expected{NodeId{"input"}, NodeId{"grade"}, NodeId{"display"}};
  const bool chain_ok = graph.Validate().empty() && graph.ValidateImageBackbone().empty()
                        && graph.TopologicalOrder() == expected;

  graph.AddNode(std::make_unique<NodeFixture>("branch", type_ids::ColorGradeNode()));
  graph.Connect(NodeId{"grade"}, PortId{"image"}, NodeId{"branch"}, PortId{"image"});
  const bool graph_ok = graph.Validate().empty();
  const auto errors = graph.ValidateImageBackbone();
  const bool rejects_branch = std::any_of(errors.begin(), errors.end(), [](const auto& error) {
    return error.code == GraphValidationCode::SceneImageFanOut;
  });

  std::cout << std::boolalpha << "chain_accepted_and_sorted=" << chain_ok
            << "\nfanout_passes_general_validation=" << graph_ok
            << "\nfanout_rejected_by_image_backbone=" << rejects_branch << '\n';
  return chain_ok && graph_ok && rejects_branch ? 0 : 1;
}
