# Development cycle using docker

Each time the `docker compose up` command runs, a full build from scratch is performed. You can optionally run `docker compose up -d` in detached mode by adding the `-d` flag. This will run the container in the background. To have faster development cycles you'll likely want to avoid building the OS from scratch each time. To avoid recreating the docker image/container each time, you have a few different routes. One such route is to pass the options `--no-op` (which is the default) to the `SS_ARGS` env variable when running `docker-compose up`. This will cause the container to skip the build steps but keep the container running in the background until you explicitly stop it. You can then launch a shell session into the container and work interactively, running any specific build commands you desire.

> **Note:** Development microSD images can also be generated on demand via a GitHub Actions build task. Visit [SeedSigner Actions](https://github.com/3rdIteration/seedsigner/actions/) to trigger a build and download the resulting image without setting up a local environment.

Using docker compose will start the container (create new container if one does not already exist) without building an image
```bash
SS_ARGS="--no-op" docker compose up -d --no-recreate
```

If you want to start a new container environment, use `--force-recreate` instead of `--no-create`
```bash
SS_ARGS="--no-op" docker compose up -d --force-recreate --build
```

Start a shell session inside the container by running
```bash
docker exec -it seedsigner-os-build-images-1 bash
```

Once you are in the container you can use the build script directly from the `/opt` directory
```bash
./build.sh --pi0 --app-repo=https://github.com/seedsigner/seedsigner.git --app-branch=dev --no-clean
```

or

```bash
./build.sh --pi0 --app-repo=https://github.com/seedsigner/seedsigner.git --app-commit-id=9c36f5c --no-clean
```

Or you can use any of the Buildroot customization commands like `make menuconfig` or `linux-menuconfig`  from the `/output` directory

Move images manually built with `make` with the command `mv images/seedsigner_os.img /images/`


## "Disk full" troubleshooting
If your build fails with the following:
```
The partition table has been altered.
Syncing disks.
mkfs.fat 4.2 (2021-01-31)
Disk full
make[1]: *** [Makefile:815: target-post-image] Error 1
make: *** [Makefile:23: _all] Error 2
```

You just need to edit the `post-image-seedsigner.sh` script in your target board's `board/` subdir (e.g. opt/pi0/board/). Edit this section:

```
# Create disk image.
dd if=/dev/zero of=disk.img bs=1M count=26 #26 MB
```

Increase the `count` to create a larger disk image and then re-run your build.


## Image Location and Naming

By default, the docker-compose.yml is configured to create a container volume of the *images* directory in the repo. This is where all the image files are written out after the container completes building the OS from source. That volume is accessible from the host. The image files are named using this convention:

`seedsigner_os.<app_repo_branch>.<board_config>.img`

Example name for a `pi0` built off the 0.5.2 branch would be named:

`seedsigner_os.0.5.2.pi0.img`


## Development Configs
Each board also has a developer configuration (dev config). Inside the `/opt` folder are all the build configs for each board matching the name of the build script option. The dev configs are built to work on each board but enable many of the kernel and OS features needed for development. This also makes the built image less secure, so please do not use those with real funds. Dev configs are only used when the `--dev` option is passed in to the build.sh script.

Dev images can also run the SeedSigner Python source directly from a MicroSD card. To enable this override, clone the SeedSigner repository to `/seedsigner` on the card (mounted at `/mnt/microsd` at runtime). On boot, a development build will display a brief notice and launch the application from the repository's `src/` directory if it exists.

## Networking and SSH

Development images automatically bring up networking to enable remote access and file transfer.

**Note: "Smartcard" build profiles are the ones I most thoroughly test... So use these if in doubt... (Even if just developing normal seedsigner releases)**

- **Ethernet:** if a cable is connected, the interface requests an IP address via DHCP at boot. (Tested with Pi2 and Pi4 integrated ethernet, also on a number of Pi models with USB-Ethernet adapters which generally work well)
- **Wi-Fi:** place a `wifi.txt` file on the root of the external MicroSD card with the network's SSID on the first line and the password on the second line. Also, open `config.txt` on the MicroSD root folder and follow the instructions in there to comment out any overlays that will prevent wifi from working. The boot script uses these credentials to connect and obtain an address via DHCP.
- **Time override:** place a `time.txt` file on the root of the external MicroSD card to override the boot clock. The file should contain a single line matching the format used by `start.sh`, for example: `2025-02-28 12:00`.
Both interfaces obtain their default gateway and DNS servers from DHCP so Internet hosts can be reached and names resolved automatically. (Tested on Pi0w, Pi02w and Pi4)

Once networked, you can connect using the Dropbear SSH server that runs by default. Development images ship with a fixed SSH key pair for the `root` user:

- Private key (OpenSSH): `docs/ssh/seedsigner_dev_ed25519`
- PuTTY key: `docs/ssh/seedsigner_dev_ed25519.ppk`
- Public key:

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINtqcotPB6Jlq1DdQhO4nvW+Zp7m/bojBhhmU1RRuxsw SeedSigner dev key
```

Copy the private key to your workstation and connect with:

```bash
ssh -i seedsigner_dev_ed25519 root@<device-ip>
```

Password logins are disabled for SSH, but the console still auto‑logs in as root with the default `passworDT` password.
The images also include `git` (with HTTPS support so repositories can be cloned directly from sites like GitHub) and `rsync` for convenient remote development and file transfer.

For basic diagnostics, development builds provide the `ping` utility as well as a `network-info` page on the device's Tools screen. The page displays the unit's hostname, assigned IP address(es), default gateway and DNS servers. The classic `ifconfig` tool is also available for inspecting or manually bringing interfaces up and down if networking does not come up automatically.

Development kernels bundle drivers for many USB-to-Ethernet adapters, so most USB network dongles work out of the box.
