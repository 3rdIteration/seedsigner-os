# Building a SeedSigner SD card image
Assemble the SeedSigner OS along with the SeedSigner application code into an image file that can be flashed to an SD card and run in your SeedSigner.
<br/>
<br/>
<br/>
## 🔥🔥🔥🛠 Quickstart: SeedSigner Reproducible Build! 🛠🔥🔥🔥

### Install Dependencies
* Docker (choose one):
    * Desktop users: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
    * Or Linux command line: [Docker Engine](https://docs.docker.com/engine/install/#server)
* Windows PowerShell users may also need to [install `git`](https://git-scm.com/download/win)

### Clone the SeedSigner OS repo
In a terminal window:

```bash
# Copy the SeedSigner OS repo to your local machine
git clone --recursive https://github.com/3rdIteration/seedsigner-os.git

# Move into the repo directory
cd seedsigner-os
```

---

### Configure and begin the build
<details><summary>macOS / Linux instructions:</summary>
<p>


#### Configure environment variables
Force Docker to build on a container meant to run on amd64 in order to get an identical result, even if your actual cpu is different:

```bash
export DOCKER_DEFAULT_PLATFORM=linux/amd64
```

Select your board type from the [Board configs](#board-configs) list below. 

If you're unsure, most people should specify `pi0`.

```bash
export BOARD_TYPE=pi0
```

Set your target release version of the SeedSigner code (see: https://github.com/SeedSigner/seedsigner/releases):

```bash

# e.g. 0.8.0, 0.7.0, etc
export RELEASE_TAG=x.y.z

```

Checkout the branch associated to the target release version of the SeedSigner code (e.g. 0.8.6, 0.8.0, etc)
```bash
git checkout $RELEASE_TAG
```

Initialize and update submodules (buildroot) from the seedsigner-os repo
```bash
git submodule init
git submodule update
```

#### Start the build!
```bash
SS_ARGS="--$BOARD_TYPE --app-repo=https://github.com/3rdIteration/seedsigner --smartcard" docker compose up --force-recreate --build
```
</p>
</details>


<details><summary>Windows PowerShell instructions:</summary>
<p>
*Note: We recommend running these steps in WSL2 (Windows Subsystem for Linux) instead of PowerShell so that you can just follow the macOS / Linux steps above.*

#### Windows prerequisites (PowerShell)
These must be set **before cloning** the repo. If you already cloned, reclone after setting these.

1) Enable **Developer Mode** in Windows (Settings → System → For Developers → Developer Mode) so Git can create symlinks.

2) Configure Git to preserve LF line endings and symlinks:
```powershell
git config --global core.autocrlf false
git config --global core.eol lf
git config --global core.symlinks true
```

Optional: verify the GCC hash file is a symlink after submodules are initialized:
```powershell
Get-Item opt/buildroot/package/gcc/gcc-initial/gcc-initial.hash | Select-Object LinkType,Target
```

#### Configure environment variables
Force Docker to build on a container meant to run on amd64 in order to get an identical result, even if your actual cpu is different:

```powershell
$env:DOCKER_DEFAULT_PLATFORM = 'linux/amd64'
```

Select your board type from the [Board configs](#board-configs) list below. 

If you're unsure, most people should specify `pi0`.

```powershell
$env:BOARD_TYPE = 'pi0'
```

Set your target release version of the SeedSigner code (see: https://github.com/SeedSigner/seedsigner/releases):

```powershell
# e.g. "0.8.0", "0.7.0", etc
$env:RELEASE_TAG = "x.y.z"  
```

Checkout the branch associated to the target release version of the SeedSigner code (e.g. 0.8.6, 0.8.0, etc)
```powershell
git checkout $env:RELEASE_TAG
```

Initialize and update submodules (buildroot) from the seedsigner-os repo
```powershell
git submodule init
git submodule update
```

#### Start the build!
```powershell
$env:SS_ARGS = "--$env:BOARD_TYPE --app-branch=$env:RELEASE_TAG"
docker compose up --force-recreate --build
```

</p>
</details>
<br>

Building can take 25min to 2.5hrs+ depending on your cpu and will require 20-30 GB of disk space.


## Build Results
When the build completes you'll see:
```bash
seedsigner-os-build-images-1  | /opt/buildroot
seedsigner-os-build-images-1  | {image hash}  /opt/../images/seedsigner_os.{RELEASE_TAG}.{BOARD_TYPE}.img
seedsigner-os-build-images-1 exited with code 0
```

The second line above will show the SHA256 hash of the image file that was built. This hash should match the hash of the release image [published on the main github repo](https://github.com/SeedSigner/seedsigner/releases) for the chosen `RELEASE_TAG` + `BOARD_TYPE` combo. If the hashes match, then you have successfully confirmed the reproducible build!

**Windows (PowerShell) note:** Even with LF line endings and symlinks enabled, some Windows builds may still produce a different image hash than the published release. WSL2 remains the recommended path for reproducible builds.

The completed image file will be in the `images` subdirectory.
```bash
cd images
ls -l

total 26628
-rw-r--r-- 1 root root       97 Sep 11 02:09 README.md
-rw-r--r-- 1 root root 27262976 Sep 11 18:49 seedsigner_os.{RELEASE_TAG}.{BOARD_TYPE}.img
```

That image can be burned to an SD card and run in your SeedSigner.




<br/>
<br/>

---


## Transient network failures

A build reaches out to the network in three places — Buildroot downloading
package sources, the `git clone` of the SeedSigner app, and `pip` — and by far
the most common cause of a failed build is one of those having a bad minute,
not anything wrong with the tree. A typical example is Buildroot's backup
mirror returning a Cloudflare `522`:

```
HTTP request sent, awaiting response... 522 <none>
ERROR 522: <none>.
make[1]: *** [package/pkg-generic.mk:179: .../.stamp_downloaded] Error 1
```

`opt/build.sh` handles these itself, so a build usually rides them out rather
than dying:

- **Downloads retry on HTTP errors.** Buildroot's default `wget -nd -t 3` does
  *not* retry an HTTP error response — `-t` only covers connection-level
  failures, so a `5xx` fails the download on the first reply. The build passes
  its own `BR2_WGET` with `--retry-on-http-error` and `--waitretry`.
- **The build itself is retried, but only when the failure looks transient.**
  Buildroot resumes from its per-package `.stamp_*` files, so a retry picks up
  at the package that failed. A genuine compile error is *not* retried — it
  fails immediately rather than repeating for hours.
- **The app clone and pip installs are retried**, with a partial checkout
  cleared before each attempt.

Tunable via the environment (defaults shown):

| Variable | Default | Purpose |
| --- | --- | --- |
| `NETWORK_MAX_ATTEMPTS` | `3` | Attempts for each network-dependent step |
| `NETWORK_RETRY_DELAY` | `30` | Seconds between attempts |
| `BR2_WGET_CMD` | `wget -nd -t 5 --waitretry=15 --timeout=30 --retry-on-http-error=...` | Buildroot's download command |

To fail fast instead of retrying, set `NETWORK_MAX_ATTEMPTS=1`. These are
forwarded into the container by `docker-compose.yml`, so they work the same way
locally and in CI.

<br/>
<br/>

---


## Board configs
| Board                        | Image Name                              | Build Script Option |
| ---------------------------- | --------------------------------------- | ------------------- |
|Raspberry Pi Zero             |`seedsigner_os.<tag>.pi0.img`            | --pi0               |
|Raspberry Pi Zero W           |`seedsigner_os.<tag>.pi0.img`            | --pi0               |
|Raspberry Pi 2 Model B        |`seedsigner_os.<tag>.pi2.img`            | --pi2               |
|Raspberry Pi Zero 2 W         |`seedsigner_os.<tag>.pi02w.img`          | --pi02w             |
|Raspberry Pi 3 Model B        |`seedsigner_os.<tag>.pi02w.img`          | --pi02w             |
|Raspberry Pi 4 Model B        |`seedsigner_os.<tag>.pi4.img`            | --pi4               |
|La Frite (AML-S805X-AC)       |`seedsigner_os.<tag>.lafrite.img`        | --lafrite           |
|Build all targets             |(all of the above)                       | --all               |

For details on the differences between dev and non-dev builds, smartcard vs non-smartcard profiles, and kernel configuration approaches per platform, see [build_profiles.md](build_profiles.md).
