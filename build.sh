#!/bin/bash
#
#    Fennec build scripts
#    Copyright (C) 2020-2024  Matías Zúñiga, Andrew Nayenko, Tavi
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public
# License along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Thin wrapper over the three build phases. CI (release.yml) runs the
# phases as separate steps so each completed toolchain can be cached before
# the next (longer, more failure-prone) phase starts; the local/F-Droid path
# keeps calling this single entry point.
#

set -e

DIR="$(dirname "$0")"
"$DIR/build-llvm.sh"
"$DIR/build-wasi.sh"
"$DIR/build-rest.sh"
