import subprocess
import os

def run():
    print("Packing web build with bumped version...")
    subprocess.run("tar -czf web_deploy_v40.tar.gz -C build/web .", shell=True, check=True)
    print("web_deploy_v40.tar.gz created.")

if __name__ == "__main__":
    run()
