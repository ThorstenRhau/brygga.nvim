if vim.g.loaded_brygga then
  return
end
vim.g.loaded_brygga = true

local subcommands = {
  start = function()
    require('brygga').start()
  end,
  stop = function()
    require('brygga').stop()
  end,
  status = function()
    require('brygga').status()
  end,
  send = function(opts)
    if not require('brygga.util').is_file_buffer(0) then
      return vim.notify('brygga: current buffer is not a file', vim.log.levels.WARN)
    end
    local path = vim.api.nvim_buf_get_name(0)
    if opts.range > 0 then
      require('brygga').send(path, opts.line1, opts.line2)
    else
      require('brygga').send(path)
    end
  end,
}

vim.api.nvim_create_user_command('Brygga', function(opts)
  local name = opts.fargs[1] or 'status'
  local subcommand = subcommands[name]
  if not subcommand then
    return vim.notify('brygga: unknown subcommand ' .. name, vim.log.levels.ERROR)
  end
  subcommand(opts)
end, {
  nargs = '?',
  range = true,
  desc = 'Claude Code IDE bridge: start, stop, status, send',
  complete = function(lead)
    return vim.tbl_filter(function(name)
      return vim.startswith(name, lead)
    end, vim.tbl_keys(subcommands))
  end,
})
