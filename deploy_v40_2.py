import subprocess
import os

def run():
    print("Packing build/web to web_deploy_v40_2.tar.gz...")
    subprocess.run("tar -czf web_deploy_v40_2.tar.gz -C build/web .", shell=True, check=True)
    print("Packed successfully.")

if __name__ == "__main__":
    run()
