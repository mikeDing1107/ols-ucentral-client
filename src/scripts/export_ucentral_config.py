#!/usr/bin/env python3

import os
import sys
from utilities_common.db import Db


CONFIG_FILE = "/var/lib/ucentral/ucentral.cfg"

def export_ucentral_config():
    try:

        db = Db()
        config_table = db.cfgdb.get_entry("UCENTRAL", "global")

        if not config_table:
            print("Error: No UCENTRAL configuration found in ConfigDB.")
            sys.exit(1)


        enable = config_table.get("enable", "")
        redirector_url = config_table.get("RedirectorURL", "")
        sn = config_table.get("SN", "")


        config_dir = os.path.dirname(CONFIG_FILE)
        if not os.path.exists(config_dir):
            os.makedirs(config_dir)
            print(f"Created directory: {config_dir}")


        with open(CONFIG_FILE, "w") as f:
            f.write(f"ENABLE={enable}\n")
            f.write(f"REDIRECTOR_URL={redirector_url}\n")
            f.write(f"SN={sn}\n")

        print(f"Successfully exported uCentral config to {CONFIG_FILE}")

    except Exception as e:
        print(f"Failed to export config: {e}")
        sys.exit(1)

if __name__ == "__main__":
    export_ucentral_config()
