# oracle-67

Two small Bash scripts that hunt for an Oracle Cloud (OCI) reserved public IP whose address **matches a regular expression you choose**.

Each script repeatedly creates a reserved public IP with the OCI CLI, tests the address against the regex (`MATCH_MODE`), **keeps it if it matches**, and **deletes it right away if it doesn't**.

The default pattern looks for `67` as a middle octet (for example `100.67.0.0` or `199.1.67.66`), but you can set any extended regex, for example:

```bash
MATCH_MODE='^129\.'                        ./one-time.sh   # starts with 129.
MATCH_MODE='\.(67|69)\.'                   ./one-time.sh   # 67 or 69 as a middle octet
MATCH_MODE='^[0-9]+\.[0-9]+\.[0-9]+\.1$'   ./one-time.sh   # ends in .1
```

The regex is matched with Bash's `[[ $ip =~ $MATCH_MODE ]]` (POSIX extended regex), so use `[0-9]` instead of `\d`, and lookaheads are not supported.

| Script | Behaviour |
| --- | --- |
| `one-time.sh` | Loops until the first match, prints its name and OCID, then exits. |
| `infinite.sh` | Never stops on its own. Keeps every match, and prints a summary when you press `i` or quit with Ctrl-C. |

## Requirements

- Bash (Linux, macOS, WSL, or Git Bash on Windows)
- [OCI CLI](https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm), installed and configured (`oci setup config`)
- Permission to create and delete public IPs in the target compartment

## Setup

### 1. Install the OCI CLI

Linux, macOS, WSL, or Git Bash:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

Windows PowerShell:

```powershell
Set-ExecutionPolicy RemoteSigned
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.ps1'))"
```

Or with pip: `pip install oci-cli`. Then check it works (open a new terminal first):

```bash
oci --version
```

### 2. Configure authentication

```bash
oci setup config
```

The wizard asks for:

- **User OCID**: OCI Console, top-right profile icon, *My profile*, copy the OCID
- **Tenancy OCID**: OCI Console, profile icon, *Tenancy: \<name\>*, copy the OCID
- **Region**: for example `ap-sydney-1`
- Whether to generate a new API key pair (answer `Y`; it writes keys to `~/.oci/`)

Then upload the **public key** so OCI accepts your requests:

1. OCI Console, profile icon, *My profile*, *API keys*, *Add API key*
2. Choose *Paste a public key* and paste the contents of `~/.oci/oci_api_key_public.pem`

The settings are saved in `~/.oci/config` (on Windows: `C:\Users\<you>\.oci\config`).

### 3. Verify the connection

```bash
oci iam region list --output table
```

A table of regions means the CLI is authenticated. A `NotAuthenticated` (401) error usually means the public key was not uploaded or the fingerprint in the config doesn't match.

### 4. Get your compartment OCID

List every compartment you can see (names and OCIDs):

```bash
oci iam compartment list --all --compartment-id-in-subtree true \
  --query "data[].{name:name, id:id}" --output table
```

Copy the `id` of the compartment you want, then export it:

```bash
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..xxxx
```

Or look it up by name and export it in one step:

```bash
export OCI_COMPARTMENT_ID=$(oci iam compartment list --all --compartment-id-in-subtree true \
  --query "data[?name=='my-compartment'].id | [0]" --raw-output)
echo "$OCI_COMPARTMENT_ID"
```

To use the **root compartment**, the value is your tenancy OCID:

```bash
export OCI_COMPARTMENT_ID=$(grep -m1 '^tenancy' ~/.oci/config | cut -d= -f2)
```

## Usage

```bash
export OCI_COMPARTMENT_ID=ocid1.compartment.oc1..xxxx
chmod +x infinite.sh one-time.sh

./one-time.sh      # stop at the first match
./infinite.sh      # keep hunting, collect all matches
```

The compartment OCID can also be passed as the first argument:

```bash
./one-time.sh ocid1.compartment.oc1..xxxx
```

On Windows, run the scripts from Git Bash or WSL, not directly from PowerShell. Make sure the files use LF line endings (`dos2unix *.sh` if needed).

## Options

Set these as environment variables.

| Variable | Default | Description |
| --- | --- | --- |
| `OCI_COMPARTMENT_ID` | (required) | Compartment OCID to create IPs in. |
| `MATCH_MODE` | `\.67\.` | Extended regex tested against the IP string. |
| `SLEEP` | `1` | Seconds to wait between attempts (minimum 1 for `infinite.sh`). |
| `MAX_TRIES` | `0` | Stop after N IPs; `0` means unlimited. |

Example with a custom pattern and a limit:

```bash
MATCH_MODE='\.(67|69)\.' MAX_TRIES=500 SLEEP=2 ./infinite.sh
```

### Default match

The default regex `\.67\.` matches when 67 is the **second or third** octet:

| IP | Match |
| --- | --- |
| `100.67.0.0` | yes |
| `199.1.67.66` | yes |
| `67.1.2.3` | no (first octet) |
| `1.2.3.67` | no (last octet) |
| `199.167.5.43` | no (167, not 67) |

## Interactive controls (`infinite.sh`)

- `i`: print a summary of matched IPs (number, IP, name, OCID) plus checked count and match rate
- `Ctrl-C`: delete the IP currently being evaluated, print the summary, and exit

## Notes

- If a create call fails (rate limit, quota), the scripts retry with exponential backoff from 10s up to 120s.
- Matched IPs are named `ip-hunt-<n>`. If a delete fails, a warning is printed so you can remove the IP manually.
- Reserved public IPs count against your tenancy's service limits, and rapid create/delete loops may be rate limited. Use a sensible `SLEEP`, and review your OCI terms and limits before running long sessions.
- Kept IPs stay in your compartment until you release them yourself:

  ```bash
  oci network public-ip delete --public-ip-id <OCID> --force
  ```
