{
  inputs = rec {
    nixpkgs.url = "github:NixOS/nixpkgs/release-23.11";
    zig-overlay.url = "github:mitchellh/zig-overlay";
  };
  outputs = inputs @ {
    self,
    nixpkgs,
    ...
  }:
  let
    pkgs = nixpkgs.legacyPackages.x86_64-linux;
    zig = inputs.zig-overlay.packages.x86_64-linux.master-2024-02-18;
  in
  {
    devShells.x86_64-linux.default = pkgs.mkShell {
      packages = with pkgs; [
        vulkan-extension-layer
        vulkan-tools
        vulkan-tools-lunarg
        vulkan-headers
        vulkan-loader
        shaderc
        spirv-tools

        glfw3
        pkg-config
        zig
      ];
      VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
    };
  };
}
