(lang dune 3.24)

(name deco)

(generate_opam_files true)

(source (github Eccl3s/deco.git))

(authors "Elliott K 354622239+Eccl3s@users.noreply.github.com")
(maintainers "Elliott K 354622239+Eccl3s@users.noreply.github.com")

(documentation https://github.com/Eccl3s/deco)

(package 
 (name deco) 
 (synopsis "Repeatable, project-local development containers in Podman")
 (description "Repeatable, project-local development containers in Podman") 
 (license "GPL-3.0-or-later")
 (depends ocaml) 
 (tags ("dev-tools" "podman")))
