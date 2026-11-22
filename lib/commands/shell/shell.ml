let run ?execute ?read_many ?probe ?hook (loaded : Config_loader.t) ~tty =
  if not tty then
    Error
      {
        Exec.cause =
          Exec.Planning "Shell entry requires stdin and stdout to be terminals";
        started = false;
      }
  else
    Exec.run ?execute ?read_many ?probe ?hook loaded ~tty:true
      [ loaded.effective.container.shell ]
