## Customizing buildroot configurations

See the Buildroot [quick start guide](https://www.buildroot.org/downloads/manual/manual.html#_buildroot_quick_start) first

## Example: Customising an Existing SeedSigner Build Profile
When running build.sh, all of the functions below run automatically... That said, when developing and debugging, it can be helpful to edit the build profile as you go.

_If you manually run the build.sh script it will do steps 1-4 for you..._

An example for how to do this is as follows:

1) Clone the repository as per normal.
```
git clone --recursive https://github.com/3rdIteration/seedsigner-os.git
```

2) Navigate to the Buildroot folder

```
cd ./seedsigner-os/opt/buildroot/
```

3) Manually download the SeedSigner repository that you want to use into the rootfs-overlay folder.
```
git clone --recurse-submodules --depth 1 -b SS0.85+Satochip+earthdriver-b6 https://github.com/3rdIteration/seedsigner ../rootfs-overlay/opt/
```

The normal build process deletes a bunch of unnessasary files from the repo, but you don't need to worry about that when developing...

4) Set the external folder and load the config (Using Pi02w-Smartcard in this example)

You will need this for all subsiquent commands. You can check that this path is correct with the following command:
```
make BR2_EXTERNAL=../pi02w-smartcard/ list-defconfigs
```

_You should see the external config in the folder you specified_ 

You can then use the name of that profile as follows:
```
make BR2_EXTERNAL=../pi02w-smartcard/  O=../../output -C ./ pi02w-smartcard_defconfig

cd ../../output
```

This will copy the config into your current working folder. 

You can then simply run.

```
Make
```

And you will end up with a seedsigner_os.img file in the output/images folder.

### Common Buildroot customization commands:

Buildroot:
```bash
make menuconfig
```

Linux Kernel:
```bash
make linux-menuconfig
```

Busybox:
```bash
busybox-menuconfig
```

## Building an image
Once you have edited an image to your liking, you can build it with:

```
make
```

If editing the profile, this won't rebuild everything, only those packages that have changed. That said, Buildroot won't always detect these changes, so the best bet is often to delete the corresponding folder in the `./output/build folder`. 

For example, if you change the Linux kernel, you can remove the previous build with
```
rm -rf ./linux-custom/
```

After the build has completed, the output will be in the ./output/ folder. (Unless you specified for it to be placed elsewhere)

In the output folder you can find the source of all packages built (build), the system environment created for the build (host) the output filesystem (target) and a folder containing images produced from these. (Including one called seedsigner_os.img that you can flash)

## Saving the edited defconfig
