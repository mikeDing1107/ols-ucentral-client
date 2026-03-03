# What is it?
This repo holds the source code for OLS (OpenLAN Switching) uCentral client implementation.
It implements both the ZTP Gateway discovery procedure (calling the ZTP Redirector and locating
the desired Gateway to connect to), as well as handlers to process the Gateway requests.
Upon connecting to the Gateway service, the device can be provisioned and controlled from the
cloud in the same manner as uCentral OpenWifi APs do.

# Prerequisites

## Required Tools

- **Docker** (20.10+) - Dockerized build environment
- **Git** (2.20+) - Version control and schema repository access
- **Make** (3.81+) - Build system

## For Testing and Database Generation

- **Python 3** (3.7+) - Test scripts and database generation
- **PyYAML** (5.1+) - YAML schema parsing

Install Python dependencies:
```bash
pip3 install -r tests/requirements.txt
# Or: pip3 install pyyaml
```

## Schema Repository

The uCentral configuration schema is maintained in a separate repository:
- **Repository:** https://github.com/Telecominfraproject/ols-ucentral-schema

Fetch schema automatically (with intelligent branch matching):
```bash
cd tests/tools
./fetch-schema.sh
```

**See [PREREQUISITES.md](PREREQUISITES.md) for complete setup guide and troubleshooting.**

# Build System
The build system implements an automated dockerized-based build enviroment to produce a final
deb package that can be installed on the target Sonic NOS.  

The deb file includes the uCentral Client docker image, that runs uCentral application.  The
uCentral application establishes a secure connection with a uCentral-schema compatible Gateway
cloud service. The GW service can then provision the device via this secure channel, and the
uCentral application applies the configuration to the underlying device.

## Build intermediate steps include:
- Generation (and tagging) of docker image that acts as a dockerized build
  enviroment (library dependencies and the uCentral app are built inside
  this build-env img);
- Compilation of the uCentral app (and libraries) inside the dockerized build
  enviroment img;
- Generation of ucentral-client docker image (consists of libraries that the
  application depends on and the uCentral app itself);
- Generation of the final deb pkg that can be installed to the target Sonic NOS
  based device (consists of the ucentral-client docker image and service scripts
  etc);

# How to use the build system (all-in-once step):
1. Build <all> target (takes a while):
```
make all
```
2. Copy final deb pkg from output/ folder (ucentral-client_1.0_amd64.deb) to the
   target device;
```
file output/*deb
  output/ucentral-client_1.0_amd64.deb: Debian binary package (format 2.0)
scp output/*deb <remote_device>
```
3. Install deb on the target device (requires root priv; must run on the target
   device):
```
cd <folder where .deb was copied to>;  
dpkg -i ./ucentral-client_1.0_amd64.deb  
```
4. uCentral service should be up and runnig (automatically initiates GW discovery,
  GW connect; connection should be established and device should be present
  in the device list on the <gw-ui> webpage;  

 **_NOTE:_** TIP certs are not part of either final build img nor the build system
       itself; these should be mounted / installed manually, or be present upon
       service start;
       Detailed GUIDE on how-to create cert partition / install certs can be found under
       <Certificates> topic below.

## Makefile targets
**all**:  
Build whole project (build-host-env, ucentral-app, ucentral-docker-img, final deb)  

**build-host-env**:  
Build *ONLY* build-host-enviroment (docker image): install toolchain, host utils,
clone / build library dependencies (e.g. cJSON, libwebsockets etc).  

Later on, this docker image used to create a docker container that compiles
the uCentral application itself.  

Depends on the root Dockerfile: img is tagged with stripped SHA of Dockerfile
to prevent redundant rebuilds of host-env img;  

Also exports img to an archive file that can be also shared / installed on another PC.  
It can be found under the following folder:  
output/docker-ucentral-client-build-env-${IMG_TAG}.gz  

**run-host-env**:  
Start host-build-enviroment docker container (a simple helper target for active development)  

**run-ucentral-docker-img**:  
Run created uCentral docker image (and uCentral application) locally.
For development / debug purposes only.  

**build-ucentral-app**:  
Build (using host-build-enviroment docker img) the uCentral application (with
all the lib dependencies).  
Copy compiled binary (and library-dependencies) to the src/docker folder.  

**build-ucentral-docker-img**:  
Build docker image, that holds the uCentral application (also libs deps).  
Docker image (ucentral-client) is also created locally, so it can be launched
on host system as well.  

**build-final-deb**:  
Technically same as 'all'. Produces final .deb pkg that can be copied to target
and installed as native deb pkg.  

# Certificates

## PKI 2.0 Architecture

The uCentral client implements **PKI 2.0** using the EST (Enrollment over Secure Transport, RFC 7030) protocol for automated certificate lifecycle management.

### Certificate Types

**Birth Certificates** (Factory-provisioned):
- `cert.pem` - Birth certificate (factory-issued)
- `key.pem` - Private key
- `cas.pem` - CA certificate bundle
- `dev-id` - Device identifier

**Operational Certificates** (Runtime-generated):
- `operational.pem` - Operational certificate (obtained via EST)
- `operational.ca` - Operational CA certificate

### Certificate Lifecycle

1. **Factory Provisioning**: Birth certificates are provisioned to the device partition during manufacturing or initial setup
2. **First Boot**: On first boot, the uCentral client automatically enrolls with the EST server using birth certificates to obtain operational certificates
3. **Runtime**: The client uses operational certificates for all gateway connections
4. **Renewal**: Operational certificates can be renewed via the `reenroll` RPC command before expiration

### Automatic EST Enrollment

The client automatically:
- Detects the EST server based on certificate issuer (QA vs Production)
- Enrolls with the EST server to obtain operational certificates
- Saves operational certificates to `/etc/ucentral/`
- Falls back to birth certificates if enrollment fails

### Installing Birth Certificates

Birth certificates should be preinstalled before launching the service. Use `partition_script.sh` (included in this repo) to provision certificates to the device partition.

**Steps (execute on device):**

1. Enter superuser mode:
```bash
sudo su
```

2. Create temp directory and copy certificates + script:
```bash
mkdir /tmp/temp
cd /tmp/temp/
scp <remote_host>:/certificates/<some_mac>.tar ./
scp <remote_host>:/partition_script.sh ./
tar -xvf ./<some_mac>.tar
```

3. Run the partition script to install birth certificates:
```bash
bash ./partition_script.sh ./
```

4. Reboot the device:
```bash
reboot
```

After reboot, the uCentral service will:
- Mount the certificate partition (ONIE-TIP-CA-CERT)
- Automatically perform EST enrollment to obtain operational certificates
- Connect to the gateway using operational certificates

### Certificate Renewal

To renew operational certificates before expiration, send the `reenroll` RPC command from the gateway:

```json
{
  "jsonrpc": "2.0",
  "id": 123,
  "method": "reenroll",
  "params": {
    "serial": "device_serial_number"
  }
}
```

The client will:
1. Contact the EST server with current operational certificate
2. Obtain a renewed operational certificate
3. Save the new certificate to `/etc/ucentral/operational.pem`
4. Restart after 10 seconds to use the new certificate

### EST Servers

- **QA**: `qaest.certificates.open-lan.org:8001` (for Demo Birth CA)
- **Production**: `est.certificates.open-lan.org` (for Production Birth CA)

The EST server is automatically selected based on the certificate issuer field.

### Certificate Files Location

- Birth certificates: `/etc/ucentral/cert.pem`, `/etc/ucentral/key.pem`, `/etc/ucentral/cas.pem`
- Operational certificates: `/etc/ucentral/operational.pem`, `/etc/ucentral/operational.ca`

# Testing

The repository includes a comprehensive testing framework for configuration validation:

## Running Tests

**Quick Start:**
```bash
# Using the test runner script (recommended)
./run-config-tests.sh

# Generate HTML report
./run-config-tests.sh --format html

# Or run tests directly in the tests directory
cd tests/config-parser
make test-config-full
```

**Docker-based Testing (recommended for consistency):**
```bash
# Run in Docker environment
docker exec ucentral_client_build_env bash -c \
  "cd /root/ols-nos/tests/config-parser && make test-config-full"
```

## Test Framework

The testing framework validates configurations through two layers:

1. **Schema Validation** - JSON structure validation against uCentral schema
2. **Parser Testing** - Actual C parser implementation testing with property tracking

Tests are organized in the `tests/` directory:
- `tests/config-parser/` - Configuration parser tests
- `tests/schema/` - Schema validation
- `tests/tools/` - Property database generation tools
- `tests/unit/` - Unit tests

## Documentation

- **[TESTING_FRAMEWORK.md](TESTING_FRAMEWORK.md)** - Testing overview and quick reference
- **[tests/README.md](tests/README.md)** - Complete testing documentation
- **[tests/config-parser/TEST_CONFIG_README.md](tests/config-parser/TEST_CONFIG_README.md)** - Detailed testing guide
- **[tests/MAINTENANCE.md](tests/MAINTENANCE.md)** - Schema and property database maintenance

## Test Configuration

Test configurations are located in `config-samples/`:
- 21 positive test configurations covering various features
- 4 negative test configurations for error handling validation
- JSON schema: `config-samples/ucentral.schema.pretty.json`
