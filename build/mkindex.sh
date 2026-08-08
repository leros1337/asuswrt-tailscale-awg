#!/bin/sh
# Generate an opkg `Packages` index for the ipk files in a directory.
#
# opkg-utils is not available on the CI runner, so the stanzas are built by
# hand from each package's own control file. Entware's opkg verifies the
# SHA256sum field per package, which is what gives us integrity without
# signing the index (Entware's opkg has no usign support).
#
# Usage: build/mkindex.sh [dir]
set -eu

DIR=${1:-out}
cd "$DIR"

: > Packages
for ipk in *.ipk; do
	[ -f "$ipk" ] || continue
	tmp=$(mktemp -d)
	# An ipk is a gzip'd tar containing control.tar.gz, not an ar archive.
	tar -xzOf "$ipk" ./control.tar.gz | tar -xzf - -C "$tmp" ./control
	# Drop blank lines so our fields join the same stanza. Continuation lines
	# of Description start with a space and have content, so they survive.
	grep -v '^[[:space:]]*$' "$tmp/control" >> Packages
	{
		printf 'Filename: %s\n' "$ipk"
		printf 'Size: %s\n' "$(wc -c < "$ipk" | tr -d ' ')"
		printf 'SHA256sum: %s\n' "$(sha256sum "$ipk" | cut -d' ' -f1)"
		printf 'MD5Sum: %s\n' "$(md5sum "$ipk" | cut -d' ' -f1)"
		printf '\n'
	} >> Packages
	rm -rf "$tmp"
done

gzip -9nkf Packages
echo "==> $DIR/Packages ($(grep -c '^Package:' Packages) package(s))"
