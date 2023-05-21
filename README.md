# Home Manager at Home

To quickly bring up my Home Manager config first install Nix then

```sh
# enable Nix flake support
mkdir -p ~/.config/nix
echo "experimental-features = nix-command flakes" >> ~/.config/nix/nix.conf
# clone my repository
git clone https://github.com/worldofgeese/home-manager-at-work ~/.config/home-manager
# bring up Home Manager config
nix run home-manager/master -- init --switch -b backup
```

Home Manager will install a suite of packages useful for work. To keep these packages updated simply run 

```sh
nix flake update ~/.config/home-manager && home-manager switch
```

The user's shell is `ble.sh`. `ble.sh` has a Nix package but it's out of date. To use `ble.sh` run

```sh
git clone --recursive --depth 1 --shallow-submodules https://github.com/akinomyoga/ble.sh.git
make -C ble.sh install PREFIX=~/.local
```

You'll need to re-enter your Bash shell to use `ble.sh`. To update run 

```sh
ble-update
```

