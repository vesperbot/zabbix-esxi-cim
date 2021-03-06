# zabbix-esxi-cim
Zabbix template to monitor VMware ESXi storage by CIM interface. Customizable.

## Installation
- On a Zabbix server install `python3-pywbem` library. This script is using this to query CIM servers for data, and some bits of Python 3 that are incompatible with Python 2 in order to urge others to make transition from Python 2. Still, as Python versions can coexist, it shouldn't be as painful.
- In case there are missing Python dependencies, the script uses argparse, json and shlex libraries which may not be available on a certain system. Install them too.
- On a ESXi to monitor, create user that can interact with CIM. Available for ESXi 5.5+, tested on 6.0 and 6.7. These commands should be invoked via SSH on your ESXi server.
    ```bash
    /usr/lib/vmware/auth/bin/adduser -s /sbin/nologin -D -H zabbix -G root
    echo "secure_zabbix_password" | /usr/lib/vmware/auth/bin/passwd --stdin zabbix
    vim-cmd vimsvc/auth/role_add CIM_ReadOnly Host.Cim.CimInteraction System.Anonymous
    vim-cmd vimsvc/auth/entity_permission_add vim.Folder:ha-folder-root 'zabbix' false CIM_ReadOnly true
    ```
    Code courtesy of [m4ce](https://github.com/m4ce/zabbix-vmware_esxi).
    If there is a vCenter user that has been granted roles on your ESXi server, you can use that user instead of making one on each server. Note that for CIM interaction permission to apply, the user should belong to `root` group on ESXi hosts.
- Put the script `pywbem-zabbix-wrapper.py` into Zabbix's "external scripts" folder, permit its execution for the user that runs `zabbix_server`
- Import the template - the file also contains mappings as of 5.0, might be required to edit (strip extra nodes) for lower versions. Current version uses Python script as backend, 0.1 version uses Bash script.

## Usage
- Create a host for your ESXi server you plan to monitor
- Use `wbemcli` to gather information about namespaces on the server, check if there are instances of `CIM_DiskDrive` or `CIM_StorageVolume` within each of them. If not found, verify if you have a CIM provider for your storage device installed. If yes, you'll have to elaborate with available class names, feel free to alter imported template for class names in discovery rules. Alternatively, this Python script can also be used to query, use internal help (thanks 
- Set up macros for your Zabbix host of the ESXi: 
  - **{$CIM_USERNAME}** should be equal to the user name provided during installation phase. The code uses "zabbix" for user name.
  - **{$CIM_PASSWORD}** - whatever password you provided in line 2.
  - **{$CIM_STORAGE_NAMESPACE}** - if not the default of `root/cimv2`, use the discovered value.
    Known values as of last update: Adaptec for smartpqi and aacraid uses `root/pmc/arc/smi_15` namespace, Emulex uses `root/emulex` namespace.
- Assign the template to the host. Verify if disk drives and storage volumes are being discovered.
