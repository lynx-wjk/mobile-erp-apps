import os
import tarfile
import subprocess
import base64

def run():
    web_dir = r"c:\Users\budic\Downloads\android\inventory_control_apps\build\web"
    tar_path = r"c:\Users\budic\Downloads\android\inventory_control_apps\web_build_v47.tar.gz"

    print("Packaging build/web to tar.gz...")
    with tarfile.open(tar_path, "w:gz") as tar:
        tar.add(web_dir, arcname=".")

    print(f"Tarball created: {os.path.getsize(tar_path)} bytes")

    # Read base64 chunks and upload/extract on VPS
    with open(tar_path, "rb") as f:
        data = f.read()

    b64_str = base64.b64encode(data).decode("utf-8")
    b64_file = r"c:\Users\budic\Downloads\android\inventory_control_apps\web_v47.b64"
    with open(b64_file, "w") as f:
        f.write(b64_str)

    print("Base64 file written!")

if __name__ == "__main__":
    run()
