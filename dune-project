(lang dune 3.24)

(name deco)

(version 0.3.0)

(generate_opam_files true)

(source (github Eccl3s/deco))

(authors "Elliott K 354622239+Eccl3s@users.noreply.github.com")
(maintainers "Elliott K 354622239+Eccl3s@users.noreply.github.com")

(documentation https://github.com/Eccl3s/deco)

(package 
 (name deco) 
 (synopsis "Repeatable, project-local development containers in Podman")
 (description "Repeatable, project-local development containers in Podman") 
 (license "GPL-3.0-or-later")
 (depends (ocaml (>= 5.5.2)) (otoml (>= 1.0.5)) (cmdliner (>= 1.3.0)) (yojson (>= 2.0)) (printbox (>= 0.12)) (printbox-text (>= 0.12)))
 (tags ("dev-tools" "podman")))
