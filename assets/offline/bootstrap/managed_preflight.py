#!/usr/bin/env python3
import argparse
import json
import os
import re
import shlex
import sys

import paramiko


def read_json(path):
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def parse_os_release(text):
    values = {}
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        v = v.strip().strip('"')
        values[k.strip()] = v
    return values


def is_supported(osr, arch):
    arch = (arch or "").strip()
    if arch not in ("x86_64", "amd64", "aarch64", "arm64"):
        return False

    os_id = (osr.get("ID") or "").lower()
    pretty = (osr.get("PRETTY_NAME") or "").lower()
    version_id = (osr.get("VERSION_ID") or "").lower()
    version = (osr.get("VERSION") or "").lower()

    if os_id == "ubuntu":
        try:
            return float(version_id) >= 24.0
        except Exception:
            return False

    combined = " ".join([os_id, pretty, version_id, version])
    looks_kylin = re.search(r"kylin", combined, re.I) is not None
    looks_v10 = re.search(r"\bv?10\b", combined, re.I) is not None
    looks_sp3 = re.search(r"\bsp3\b", combined, re.I) is not None or re.search(
        r"\blance\b", combined, re.I
    ) is not None
    return looks_kylin and looks_v10 and looks_sp3


def bundle_key_for_arch(arch):
    if arch in ("x86_64", "amd64"):
        return "linux-x86_64"
    if arch in ("aarch64", "arm64"):
        return "linux-aarch64"
    return "linux-%s" % arch


def ssh_run(client, cmd):
    stdin, stdout, stderr = client.exec_command(cmd)
    out = stdout.read().decode("utf-8", errors="ignore")
    err = stderr.read().decode("utf-8", errors="ignore")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def ensure_remote_dir(client, path):
    cmd = "mkdir -p %s" % shlex.quote(path)
    return ssh_run(client, "bash -lc %s" % shlex.quote(cmd))


def ensure_chmod(client, path):
    cmd = "chmod +x %s" % shlex.quote(path)
    return ssh_run(client, "bash -lc %s" % shlex.quote(cmd))


def run_with_sudo(client, password, cmd):
    code, out, err = ssh_run(client, "id -u")
    if code == 0 and out.strip() == "0":
        return ssh_run(client, "bash -lc %s" % shlex.quote(cmd))

    code, _, _ = ssh_run(client, "sudo -n true")
    if code == 0:
        sudo_cmd = "sudo -n /bin/bash -lc %s" % shlex.quote(cmd)
        return ssh_run(client, "bash -lc %s" % shlex.quote(sudo_cmd))

    if "\n" in password:
        return 99, "", "sudo password contains newline"

    pw = shlex.quote(password)
    inner = "/bin/bash -lc %s" % shlex.quote(cmd)
    sudo_cmd = "printf '%s\\n' %s | sudo -S -p '' %s" % (pw, pw, inner)
    return ssh_run(client, "bash -lc %s" % shlex.quote(sudo_cmd))


def has_python(client, python_bin, major, minor):
    inner = (
        "test -x {py} && {py} -c \"import sys; "
        "raise SystemExit(0 if sys.version_info[:2]==({major},{minor}) else 3)\""
    ).format(py=shlex.quote(python_bin), major=major, minor=minor)
    code, _, _ = ssh_run(client, "bash -lc %s" % shlex.quote(inner))
    return code == 0


def sftp_put(client, local_path, remote_path):
    sftp = client.open_sftp()
    try:
        sftp.put(local_path, remote_path)
    finally:
        sftp.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True)
    args = ap.parse_args()

    cfg = read_json(args.config)
    python_bin = cfg["python_bin"]
    python_version = cfg["python_version"]
    install_script = cfg["install_script"]
    archives = cfg["archives"]
    remote_dir = cfg["remote_dir"]
    servers = cfg["servers"]

    parts = python_version.split(".")
    major = int(parts[0]) if parts else 3
    minor = int(parts[1]) if len(parts) > 1 else 12

    results = []
    ok = True

    for s in servers:
        item = {
            "id": s.get("id"),
            "host": s.get("host"),
            "ok": True,
            "error": "",
        }
        try:
            client = paramiko.SSHClient()
            client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            client.connect(
                s["host"],
                port=s.get("port", 22),
                username=s["username"],
                password=s.get("password", ""),
                timeout=12,
            )
            try:
                code, os_text, _ = ssh_run(client, "cat /etc/os-release")
                osr = parse_os_release(os_text if code == 0 else "")
                code, arch_text, _ = ssh_run(client, "uname -m")
                arch = (arch_text or "").strip()

                if not is_supported(osr, arch):
                    item["ok"] = False
                    item["error"] = (
                        "unsupported os/arch: %s %s"
                        % (osr.get("PRETTY_NAME", "unknown"), arch)
                    )
                    results.append(item)
                    ok = False
                    continue

                if has_python(client, python_bin, major, minor):
                    results.append(item)
                    continue

                bundle_key = bundle_key_for_arch(arch)
                local_archive = archives.get(bundle_key)
                if not local_archive or not os.path.isfile(local_archive):
                    item["ok"] = False
                    item["error"] = "missing archive for %s" % bundle_key
                    results.append(item)
                    ok = False
                    continue

                code, _, err = ensure_remote_dir(client, remote_dir)
                if code != 0:
                    item["ok"] = False
                    item["error"] = "mkdir failed: %s" % err.strip()
                    results.append(item)
                    ok = False
                    continue

                remote_script = os.path.join(remote_dir, "install_managed_python.sh")
                remote_archive = os.path.join(
                    remote_dir, os.path.basename(local_archive)
                )
                sftp_put(client, install_script, remote_script)
                sftp_put(client, local_archive, remote_archive)
                ensure_chmod(client, remote_script)

                install_dir = cfg["install_dir"]
                cmd = " ".join(
                    [
                        shlex.quote(remote_script),
                        "--python-archive",
                        shlex.quote(remote_archive),
                        "--python-install-dir",
                        shlex.quote(install_dir),
                        "--python-bin",
                        shlex.quote(python_bin),
                    ]
                )
                code, out, err = run_with_sudo(client, s.get("password", ""), cmd)
                if code != 0:
                    item["ok"] = False
                    item["error"] = "install failed: %s %s" % (out.strip(), err.strip())
                    results.append(item)
                    ok = False
                    continue

                if not has_python(client, python_bin, major, minor):
                    item["ok"] = False
                    item["error"] = "python not available after install"
                    results.append(item)
                    ok = False
                    continue

                results.append(item)
            finally:
                client.close()
        except Exception as e:
            item["ok"] = False
            item["error"] = str(e)
            results.append(item)
            ok = False

    result = {"ok": ok, "results": results}
    print(json.dumps(result, ensure_ascii=True))
    return 0 if ok else 2


if __name__ == "__main__":
    sys.exit(main())
