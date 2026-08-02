import subprocess
import json
import os

def deploy():
    print("Packing web build...")
    cmd_tar = "tar -czf web_deploy_fixed.tar.gz -C build/web ."
    subprocess.run(cmd_tar, shell=True, check=True)
    print("web_deploy_fixed.tar.gz created.")

if __name__ == "__main__":
    deploy()
