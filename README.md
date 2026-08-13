# WebGPU Zig

## Installing dependencies

### macOS

```bash
# Install GLFW and wgpu-native using Homebrew
brew install glfw wgpu-native
```

### Linux (Arch)

```bash
# Install GLFW and X11/Wayland libraries
sudo pacman -S glfw-x11 libx11 libxcursor libxrandr libxi wayland

# Install wgpu-native from AUR (using yay or paru)
yay -S wgpu-native
# or
paru -S wgpu-native
```

### Windows

- Download [wgpu-native](https://github.com/gfx-rs/wgpu-native/releases/v27.0.4.0) and put its content in your msys64 folder (``C:/msys64/mingw64``) (version v27.0.4.0)
- Run ``pacman -S mingw-w64-x86_64-glfw`` in msys2 terminal