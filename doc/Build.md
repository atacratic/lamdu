# Building Lamdu from source

## General notes

### NodeJS

To drastically speed up Lamdu's installation under any OS, you can install
an appropriate version of NodeJS beforehand, such that `node` is in your `$PATH`. The version has to be at least 6.2.1 but below 8.0.0 (due to the removal of tail call optimization from node at version 8) <sup>1</sup>.

Enter `node -v` into terminal. If NodeJS is installed (and in your `$PATH`),
this will print your current version. If it isn't, you'll get an error.

If you do not install NodeJS, Lamdu's installation will build it from
source.

<sup>
**1. For Fedora Users:**
Fedora packages have very long names. This may lead to some confusion.
Consider `nodejs-1:6.11.2-1.fc25.x86_64`.
This example indicates a NodeJS version of `6.11`, plus a little.
The `-1:` is not a part of the version.
</sup>

## Platforms

### macOS

requires [brew](http://brew.sh/) and [git](https://git-scm.com/):

```shell
brew install leveldb haskell-stack
git clone --recursive https://github.com/lamdu/lamdu
cd lamdu
stack setup
~/.local/bin/lamdu
```

### ubuntu

Optional: Install NodeJS from node's apt repository:

```shell
curl -sL https://deb.nodesource.com/setup_6.x | sudo -E bash -
sudo apt-get install -y nodejs
```

requires [stack](https://github.com/commercialhaskell/stack/releases) (version 1.6.1 or above)

```shell
sudo apt-get update -qq
sudo apt-get install git zlib1g-dev libglew-dev libleveldb-dev -yq
sudo apt-get install libxrandr-dev libxi-dev libxcursor-dev libxinerama-dev -yq
git clone --recursive https://github.com/lamdu/lamdu
cd lamdu
stack setup
stack install
~/.local/bin/lamdu
```

If the above fails at `stack setup` or `stack install`, it may because stack is older than 1.6.1. To upgrade stack, run the following commands:

```shell
stack upgrade
hash -r
```

NOTE: `~/.local/bin` should be in your `$PATH` for the upgraded `stack` to take effect.

### fedora

Optional: Install NodeJS with `sudo dnf insall nodjs`.
Please see the starred note under "NodeJS & Build Time".

requires [stack](https://github.com/commercialhaskell/stack/releases) (1.6.1 or above)

```shell
sudo dnf install -y gcc gcc-c++ gmp-devel libXrandr-devel libXi-devel
sudo dnf install -y libXcursor-devel mesa-libGL-devel libGLU-devel
sudo dnf install -y libXinerama-devel leveldb-devel glew-devel zlib-devel
git clone --recursive https://github.com/lamdu/lamdu
cd lamdu
stack setup
stack install
~/.local/bin/lamdu
```

If the above fails at `stack setup` or `stack install`, it may because stack is older than 1.6.1. To upgrade stack, run the following commands:

```shell
stack upgrade
hash -r
```

NOTE: `~/.local/bin` should be in your `$PATH` for the upgraded `stack` to take effect.

### arch linux

requires [stack](https://github.com/commercialhaskell/stack/releases) (1.6.1 or above)

```shell
sudo pacman -S leveldb glfw libxrandr libxi libxcursor libxinerama
git clone --recursive https://github.com/lamdu/lamdu
cd lamdu
stack setup
stack install
~/.local/bin/lamdu

```

### nix (any linux distribution)

requires [Nix](https://nixos.org/nix/)

```shell
git clone --recursive https://github.com/lamdu/lamdu
cd lamdu
nix-env -f default.nix -iA lamdu
```

### Windows

Install:

* [git](https://git-scm.com/)
* [stack](https://haskellstack.org/)
* [msys2](http://msys2.org/)
* [NVM for Windows](https://github.com/coreybutler/nvm-windows) (a NodeJS distribution)

In the msys2 shell:

    pacman -S mingw-w64-x86_64-{,c}make

Add `c:\msys64\mingw64\bin` to your `PATH`.

In the Windows `cmd.exe` shell:

    nvm install 7.10.1
    nvm use 7.10.1

    stack setup

    rem "fastogt" maintain a leveldb fork that is compatible with stack/Haskell (builds with mingw-w64-x86_64)
    git clone https://github.com/fastogt/leveldb.git
    cd leveldb
    cmake -G "MinGW Makefiles" . -DCMAKE_C_COMPILER=C:/Users/%username%/AppData/Local/Programs/stack/x86_64-windows/ghc-8.4.3/mingw/bin/gcc.exe
    mingw32-make
    cd ..

    git clone https://github.com/lamdu/lamdu.git
    stack build --extra-lib-dirs=%cd%\..\leveldb --extra-include-dirs=%cd%\..\leveldb\include
    stack exec lamdu

Notes:

* If `cmake` fails complaining about `sh` being in the path, remove its provider from the path (most likely OpenSSH) and try invoking `cmake` again.
