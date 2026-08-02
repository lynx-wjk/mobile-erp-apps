import subprocess

def run():
    print("Packing build/web to web_deploy_v46.tar.gz...")
    subprocess.run("tar -czf web_deploy_v46.tar.gz -C build/web .", shell=True, check=True)
    print("Packed web_deploy_v46.tar.gz successfully.")

if __name__ == "__main__":
    run()
