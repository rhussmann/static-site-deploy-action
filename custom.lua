local scheme = kong.request.get_scheme()
if scheme == "http" and not string.starts(kong.request.get_path(), "/.well-known/acme-challenge/") then
  local host = kong.request.get_host()
  local query = kong.request.get_path_with_query()
  local url = "https://" .. host ..query
  kong.response.set_header("Location",url)
  return kong.response.exit(302,url)
end