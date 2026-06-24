param()

$ErrorActionPreference = "Stop"

$WxautoEnv = & (Join-Path $PSScriptRoot "wxauto-env.ps1")

if (-not (Test-Path -LiteralPath $WxautoEnv.VenvPython)) {
  throw "Python venv not found."
}

$script = @"
import os
import sys
import yaml
import ast

api_config_path = r"$($WxautoEnv.ApiRoot)\config.yaml"
listen_service_path = r"$($WxautoEnv.ApiRoot)\app\services\listen_service.py"
project_src = r"$($WxautoEnv.ProjectRoot)\src"
channel_root = r"$($WxautoEnv.WxChannelRoot)"
channel_config_path = os.path.join(channel_root, "config.yaml")

if not os.path.exists(api_config_path):
    raise SystemExit(f"missing api config: {api_config_path}")
if not os.path.exists(channel_config_path):
    raise SystemExit(f"missing channel config: {channel_config_path}")
if not os.path.exists(listen_service_path):
    raise SystemExit(f"missing listen service: {listen_service_path}")

with open(api_config_path, "r", encoding="utf-8") as f:
    api_config = yaml.safe_load(f)
assert api_config["server"]["host"] == "127.0.0.1"
assert int(api_config["server"]["port"]) > 0
assert api_config["database"]["type"] == "sqlite"
assert api_config["database"]["sqlite"]["path"]
assert api_config["auth"]["token"]

sys.path.insert(0, channel_root)
from wxauto_channel import Config, MessageFilter
sys.path.insert(0, project_src)
from aipet_wxauto_bridge_channel.channel import ChannelConfig

config = Config(channel_config_path)
assert config.wxapi_base_url
assert config.wxapi_token
assert config.openclaw_gateway_url
assert config.openclaw_agent_id
assert config.my_nickname

message_filter = MessageFilter(config)
targets = message_filter.all_targets()
assert targets, "at least one private or group target must be configured"

with open(listen_service_path, "r", encoding="utf-8-sig") as f:
    listen_tree = ast.parse(f.read(), filename=listen_service_path)

safe_contacts = None
sandbox_mode = None
for node in listen_tree.body:
    if isinstance(node, ast.AnnAssign) and isinstance(node.target, ast.Name):
        if node.target.id == "SAFE_CONTACTS":
            safe_contacts = ast.literal_eval(node.value)
        elif node.target.id == "SANDBOX_MODE":
            sandbox_mode = ast.literal_eval(node.value)
assert sandbox_mode is True, "wxauto API listen sandbox must be enabled"
assert safe_contacts == set(targets), (
    f"wxauto API safe contacts {safe_contacts} != channel targets {set(targets)}"
)

aipet_config = ChannelConfig.from_yaml(channel_config_path)
assert aipet_config.bridge_url
assert aipet_config.pet_id
assert aipet_config.target_names
assert len(aipet_config.target_names) == len(targets), (
    f"AI Pet target count {len(aipet_config.target_names)} != reference target count {len(targets)}"
)
assert aipet_config.allowed_message_types == ("text",), (
    f"allowed_message_types must be chat-only text, got {aipet_config.allowed_message_types}"
)
assert aipet_config.require_openclaw_for_send is True, (
    "require_openclaw_for_send must stay enabled for real WeChat sends"
)

print("wxauto_config_ok")
print("target_count=" + str(len(targets)))
print("private_count=" + str(len([c for c in config.private_chats if c.get("enabled", True)])))
print("group_count=" + str(len([g for g in config.group_chats if g.get("enabled", True)])))
print("allowed_message_types=" + ",".join(aipet_config.allowed_message_types))
print("require_openclaw_for_send=" + str(aipet_config.require_openclaw_for_send).lower())
print("api_listen_sandbox=true")
print("api_safe_contacts=" + str(len(safe_contacts)))
"@

$script | & $WxautoEnv.VenvPython -
