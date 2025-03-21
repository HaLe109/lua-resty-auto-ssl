local _M = {}

local shell_execute = require "resty.auto-ssl.utils.shell_execute"

function _M.issue_cert(auto_ssl_instance, domain)
  assert(type(domain) == "string", "domain must be a string")

  local lua_root = auto_ssl_instance.lua_root
  assert(type(lua_root) == "string", "lua_root must be a string")

  local base_dir = auto_ssl_instance:get("dir")
  assert(type(base_dir) == "string", "dir must be a string")

  local hook_port = auto_ssl_instance:get("hook_server_port")
  assert(type(hook_port) == "number", "hook_port must be a number")
  assert(hook_port <= 65535, "hook_port must be below 65536")

  local hook_secret = ngx.shared.auto_ssl_settings:get("hook_server:secret")
  assert(type(hook_secret) == "string", "hook_server:secret must be a string")

  -- Run dehydrated for this domain, using our custom hooks to handle the
  -- domain validation and the issued certificates.
  --
  -- Disable dehydrated's locking, since we perform our own domain-specific
  -- locking using the storage adapter.
  ngx.log(ngx.ERR, "auto-ssl-more-logs: shell_execute: ", domain)
  local result, err = shell_execute({
    "env",
    "HOOK_SECRET=" .. hook_secret,
    "HOOK_SERVER_PORT=" .. hook_port,
    lua_root .. "/bin/resty-auto-ssl/dehydrated",
    "--cron",
    "--accept-terms",
    "--no-lock",
    "--domain", domain,
    "--challenge", "http-01",
    "--config", base_dir .. "/letsencrypt/config",
    "--hook", lua_root .. "/bin/resty-auto-ssl/letsencrypt_hooks",
  })
  ngx.log(ngx.ERR, "auto-ssl-more-logs: result", result["command"], " status: ", result["status"], " out: ", result["output"], " err: ", err)
  -- Cleanup dehydrated files after running to prevent temp files from piling
  -- up. This always runs, regardless of whether or not dehydrated succeeds (in
  -- which case the certs should be installed in storage) or dehydrated fails
  -- (in which case these files aren't of much additional use).
  _M.cleanup(auto_ssl_instance, domain)

  if result["status"] ~= 0 then
    ngx.log(ngx.ERR, "auto-ssl: dehydrated failed: ", result["command"], " status: ", result["status"], " out: ", result["output"], " err: ", err)
    return nil, "dehydrated failure"
  end

  ngx.log(ngx.DEBUG, "auto-ssl: dehydrated output: " .. result["output"])

  -- The result of running that command should result in the certs being
  -- populated in our storage (due to the deploy_cert hook triggering).
  local storage = auto_ssl_instance.storage
  local cert, get_cert_err = storage:get_cert(domain)
  if get_cert_err then
    ngx.log(ngx.ERR, "auto-ssl: error fetching certificate from storage for ", domain, ": ", get_cert_err)
  end

  -- Return error if things are still unexpectedly missing.
  if not cert or not cert["fullchain_pem"] or not cert["privkey_pem"] then
    return nil, "dehydrated succeeded, but no certs present"
  end

  return cert
end

function _M.cleanup(auto_ssl_instance, domain)
  assert(string.find(domain, "/") == nil)
  assert(string.find(domain, "%.%.") == nil)

  local dir = auto_ssl_instance:get("dir") .. "/letsencrypt/certs/" .. domain
  local _, rm_err = shell_execute({ "rm", "-rf", dir })
  if rm_err then
    ngx.log(ngx.ERR, "auto-ssl: failed to cleanup certs: ", rm_err)
  end
end

return _M
