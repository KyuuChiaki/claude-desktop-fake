# Unicode CLDR 48 mapping data

`windowsZones.xml` is the unchanged Unicode CLDR `release-48` file from
<https://raw.githubusercontent.com/unicode-org/cldr/release-48/common/supplemental/windowsZones.xml>.
Its SHA-256 is `9cf3db6a31fb382fee21b70be6feba1e82766b0fcd06e6261fb7936a73e537ff`.

Only world-default (`territory="001"`) mappings are compiled into
`include/windows_iana_cldr48.inc`. The independent configured home region is
not used to select an IANA time zone. Regenerate the table using
`python scripts/Generate-WindowsIana.py`.

Copyright Unicode, Inc. The data is distributed under Unicode License v3;
the full license is included in `LICENSE`.
