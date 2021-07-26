local scheme = kong.request.get_scheme()
local acme_prefix = "/.well-known/acme-challenge/"
if scheme == "http" and not kong.request.get_path():sub(1, #acme_prefix) == acme_prefix then
  local host = kong.request.get_host()
  local query = kong.request.get_path_with_query()
  local url = "https://" .. host ..query
  kong.response.set_header("Location",url)
  return kong.response.exit(302,url)
end