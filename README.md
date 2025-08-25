docker build -t create-do-droplet .

echo '{
  "state": {},
  "params": {
    "do_access_token": "<access_token>",
    "droplet_name": "starthub-demo",
    "region": "nyc3",
    "size": "s-1vcpu-2gb",
    "image": "ubuntu-22-04-x64",
    "ssh_keys": [123456, "aa:bb:cc:dd:ee:ff:11:22:33:44:55:66:77:88:99:00"],
    "tags": ["starthub", "demo"],
    "backups": true,
    "ipv6": true,
    "monitoring": true,
    "vpc_uuid": "your-vpc-uuid-if-any",
    "user_data": "#cloud-config\nruncmd:\n  - echo hello from starthub > /root/hello.txt"
  }
}' | docker run -i --rm create-do-droplet
