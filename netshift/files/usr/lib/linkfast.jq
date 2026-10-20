# Share links to sing-box outbounds, many at once.
#
# The slow path (sing_box_cf_add_proxy_outbound, one link at a time) starts about ten
# processes per link, which is minutes for a published list of thousands of servers. This
# program does the same for the common kinds of link in ONE jq run. It never guesses:
# a link it is not sure about (a rare transport or parameter, an escape that is not UTF-8,
# a feature the core lacks...) is reported as "slow" and goes the slow way, so the result
# is the same as before, only faster. There is no regular expression in it (jq on OpenWrt
# has none); tests/entrypoint.sh compares it with the slow path on real lists.
#
# Input: one link per line (raw, trimmed, no comments). Arguments:
#   $opt = {quic: bool, utls: bool, extended: bool, udp_over_tcp: "1"|"", base: number}
# Output, one object per link: {"i": n, "s": "ok", "name": "...", "ob": {...}} or
# {"i": n, "s": "slow"}.

def hexval:
  if . >= 48 and . <= 57 then . - 48
  elif . >= 65 and . <= 70 then . - 55
  elif . >= 97 and . <= 102 then . - 87
  else null end;

def utf8enc:
  if . < 128 then [.]
  elif . < 2048 then [192 + ((. / 64) | floor), 128 + (. % 64)]
  elif . < 65536 then [224 + ((. / 4096) | floor), 128 + (((. / 64) | floor) % 64), 128 + (. % 64)]
  else [240 + ((. / 262144) | floor), 128 + (((. / 4096) | floor) % 64), 128 + (((. / 64) | floor) % 64), 128 + (. % 64)] end;

# bytes -> string, or null when they are not valid UTF-8
def bytes_to_str:
  . as $b
  | ($b | length) as $n
  | {i: 0, out: [], bad: false}
  | until(.i >= $n or .bad;
      $b[.i] as $x
      | if $x < 128 then (.out += [$x] | .i += 1)
        elif $x >= 194 and $x <= 223 then
          (if .i + 1 < $n and $b[.i + 1] >= 128 and $b[.i + 1] <= 191
           then (.out += [($x - 192) * 64 + ($b[.i + 1] - 128)] | .i += 2)
           else .bad = true end)
        elif $x >= 224 and $x <= 239 then
          (if .i + 2 < $n and $b[.i + 1] >= 128 and $b[.i + 1] <= 191 and $b[.i + 2] >= 128 and $b[.i + 2] <= 191
           then (($x - 224) * 4096 + ($b[.i + 1] - 128) * 64 + ($b[.i + 2] - 128)) as $cp
                | (if $cp < 2048 or ($cp >= 55296 and $cp <= 57343) then .bad = true
                   else (.out += [$cp] | .i += 3) end)
           else .bad = true end)
        elif $x >= 240 and $x <= 244 then
          (if .i + 3 < $n and $b[.i + 1] >= 128 and $b[.i + 1] <= 191 and $b[.i + 2] >= 128 and $b[.i + 2] <= 191 and $b[.i + 3] >= 128 and $b[.i + 3] <= 191
           then (($x - 240) * 262144 + ($b[.i + 1] - 128) * 4096 + ($b[.i + 2] - 128) * 64 + ($b[.i + 3] - 128)) as $cp
                | (if $cp < 65536 or $cp > 1114111 then .bad = true
                   else (.out += [$cp] | .i += 4) end)
           else .bad = true end)
        else .bad = true end)
  | if .bad then null else (.out | implode) end;

# percent decoding; null when the result is not UTF-8 or has a NUL
def pdecode:
  if contains("%") | not then .
  else
    explode as $c
    | ($c | length) as $n
    | (reduce range(0; $n) as $k ({skip: 0, b: []};
        if .skip > 0 then .skip -= 1
        elif $c[$k] == 37 and $k + 2 < $n
             and (($c[$k + 1] | hexval) != null) and (($c[$k + 2] | hexval) != null)
        then (.b += [(($c[$k + 1] | hexval) * 16) + ($c[$k + 2] | hexval)] | .skip = 2)
        else .b += ($c[$k] | utf8enc) end))
    | .b
    | if index(0) != null then null else bytes_to_str end
  end;

# the value of a query parameter as the slow path reads it: the last one wins, "+" is a
# space (unless it is a component), then percent decoding; null when it is not UTF-8
def qv($pairs; $name; $component):
  ([$pairs[] | select(.[0] == $name)] | last // null) as $p
  | if $p == null then ""
    else ($p[1] | if ($component or (contains("+") | not)) then . else (split("+") | join(" ")) end | pdecode) end;

def is_digits: length > 0 and (explode | all(. >= 48 and . <= 57));

# the TLS block of the link; {} for none, null when the link must go the slow way
def tls_block($pairs; $opt; $tls_default):
  qv($pairs; "security"; false) as $sec0
  | (if $sec0 == "" and $tls_default then "tls" else $sec0 end) as $sec
  | if $sec == null then null
    elif ($sec == "tls" or $sec == "reality") then
      qv($pairs; "sni"; false) as $sni
      | qv($pairs; "allowInsecure"; false) as $a1
      | qv($pairs; "insecure"; false) as $a2
      | qv($pairs; "allow_insecure"; false) as $a3
      | (if $a1 != "" then $a1 elif $a2 != "" then $a2 else $a3 end) as $insecure
      | qv($pairs; "alpn"; false) as $alpn
      | qv($pairs; "fp"; false) as $fp
      | qv($pairs; "pbk"; false) as $pbk
      | qv($pairs; "sid"; false) as $sid
      | if [$sni, $insecure, $alpn, $fp, $pbk, $sid] | any(. == null) then null
        elif ($alpn | contains("\"")) then null
        # the slow path writes the ML-KEM hint of the link into the node and the batch step
        # acts on it: such a link is left to it
        elif ($pairs | any(.[0] == "support-x25519mlkem768")) then null
        elif ($fp != "" and ($opt.utls | not)) then null
        elif ($sec == "reality" and ($opt.utls | not)) then null
        else {enabled: true}
             + (if $sni != "" then {server_name: $sni} else {} end)
             + (if $insecure == "1" then {insecure: true} else {} end)
             + (if $alpn != "" then {alpn: ($alpn | split(","))} else {} end)
             + (if $fp != "" then {utls: {enabled: true, fingerprint: $fp}} else {} end)
             + (if $pbk != "" then {reality: {enabled: true, public_key: $pbk, short_id: $sid}} else {} end)
        end
    elif ($sec == "" or $sec == "none" or $sec == "false" or $sec == "0" or $sec == "off" or $sec == "no" or $sec == "disable" or $sec == "disabled") then {}
    else null end;

# the transport block; {} for plain TCP, null for the slow way
def transport_block($pairs):
  qv($pairs; "type"; false) as $t
  | if $t == null then null
    elif ($t == "tcp" or $t == "raw" or $t == "") then {}
    elif $t == "ws" then
      qv($pairs; "path"; false) as $path | qv($pairs; "host"; false) as $h | qv($pairs; "ed"; false) as $ed
      | if [$path, $h, $ed] | any(. == null) then null
        elif $ed != "" and ($ed | is_digits | not) then null
        else {transport: ({type: "ws", path: $path}
              + (if $h != "" then {headers: {Host: $h}} else {} end)
              + (if $ed != "" then {max_early_data: ($ed | tonumber)} else {} end))} end
    elif $t == "grpc" then
      qv($pairs; "serviceName"; false) as $sn
      | if $sn == null then null
        else {transport: ({type: "grpc"} + (if $sn != "" then {service_name: $sn} else {} end))} end
    elif $t == "httpupgrade" then
      qv($pairs; "path"; false) as $path | qv($pairs; "host"; false) as $h | qv($pairs; "sni"; false) as $sni
      | if [$path, $h, $sni] | any(. == null) then null
        else {transport: ({type: "httpupgrade", path: (if $path == "" then "/" else $path end)}
              + (if ($h != "" or $sni != "") then {host: (if $h != "" then $h else $sni end)} else {} end))} end
    else null end;

# splits a link into its parts; null when it is not one of the plain forms
def parse_link:
  . as $line
  | ($line | split("#")) as $hashes
  | $hashes[0] as $url
  | ($url | split("://")) as $sp
  | if ($sp | length) < 2 then null else
    $sp[0] as $scheme
    | ($sp[1:] | join("://")) as $rest
    | ($rest | split("?")) as $qp
    | if ($line | contains("\\")) then null else
      ($qp[0] | split("/")[0]) as $authority
      # a "?" inside a value ends it, as in the slow path: both "?" and "&" separate parameters
      | (if ($qp | length) > 1 then ($qp[1:] | join("&")) else "" end) as $query
      | (if ($qp[0] | contains("@")) and (($authority | contains("@")) | not) then null else $authority end) as $auth
      | if $auth == null then null else
        ($auth | split("@")) as $ap
        | if ($ap | length) > 2 then null else
          (if ($ap | length) == 2 then $ap[0] else "" end) as $ui
          | (if ($ap | length) == 2 then $ap[1] else $ap[0] end) as $hostport
          | (if ($hostport | startswith("[")) then
               (($hostport | ltrimstr("[") | split("]")) as $b
                | if ($b | length) == 2 and ($b[1] == "" or ($b[1] | startswith(":"))) then {host: $b[0], port: ($b[1] | ltrimstr(":"))} else null end)
             else
               (($hostport | split(":")) as $h
                | if ($h | length) <= 2 then {host: $h[0], port: (if ($h | length) == 2 then $h[1] else "" end)} else null end)
             end) as $hp
          | if $hp == null or $hp.host == "" then null else
            {scheme: $scheme, ui: $ui, host: $hp.host, port: $hp.port,
             pairs: ($query | if . == "" then [] else (split("&") | map(split("=") | if length < 2 then empty else [.[0], (.[1:] | join("="))] end)) end),
             frag: (if ($hashes | length) > 1 then $hashes[-1] else "" end)}
          end
        end
      end
    end
  end;

# standard base64 text -> the decoded text; null when it is not clean (an alphabet of its own,
# a wrong padding, bytes that are not UTF-8, a NUL or a line break in the result)
def b64text:
  . as $s
  | ($s | until(endswith("=") | not; rtrimstr("="))) as $t
  | (($s | length) - ($t | length)) as $eq
  | ($t | explode) as $c
  | ($c | length) as $m
  | if $m == 0 or $eq > 2 or ($m % 4) == 1 or ($eq > 0 and (($m + $eq) % 4) != 0) then null
    elif ($c | all((. >= 65 and . <= 90) or (. >= 97 and . <= 122) or (. >= 48 and . <= 57) or . == 43 or . == 47) | not) then null
    else
      (try ($t | @base64d) catch null) as $d
      | if $d == null then null
        elif ($d | explode | any(. == 65533 or . == 0 or . == 10 or . == 13)) then null
        else $d end
    end;

# a field of the VMess JSON as the slow path reads it (`.x // "" | tostring`); null when it
# is something else than a string, a number or a flag, or has a line break
def fld($o; $k):
  $o[$k] as $v
  | (if $v == null or $v == false then ""
     elif ($v | type) == "string" then $v
     elif ($v | type) == "number" then ($v | tostring)
     elif $v == true then "true"
     else null end) as $r
  | if $r != null and ($r | contains("\n")) then null else $r end;

def vmess_convert($line; $opt):
  ($line | ltrimstr("vmess://") | split("#")[0]) as $payload
  | ($line | split("#")) as $hashes
  | ((if ($hashes | length) > 1 then $hashes[-1] else "" end) | if contains("+") then (split("+") | join(" ")) else . end | pdecode) as $name
  | if ($opt.extended | not) or $name == null then {s: "slow"} else
    ($payload | b64text) as $txt
    | (if $txt == null then null else ($txt | try fromjson catch null) end) as $o
    | if ($o | type) != "object" then {s: "slow"} else
      fld($o; "add") as $server | fld($o; "port") as $port | fld($o; "id") as $uuid
      | fld($o; "scy") as $scy | fld($o; "aid") as $aid | fld($o; "net") as $net
      | fld($o; "host") as $host | fld($o; "path") as $path | fld($o; "tls") as $tls
      | fld($o; "sni") as $sni | fld($o; "alpn") as $alpn | fld($o; "fp") as $fp
      | if [$server, $port, $uuid, $scy, $aid, $net, $host, $path, $tls, $sni, $alpn, $fp] | any(. == null) then {s: "slow"}
        elif ($port | is_digits | not) or ($port | length) > 5 or ($port | startswith("0")) then {s: "slow"}
        elif $aid != "" and $aid != "0" and ($aid | is_digits | not) then {s: "slow"}
        elif ($alpn | explode | any(. < 32 or . == 34 or . == 92)) then {s: "slow"}
        else
          (if $net == "ws" then {transport: ({type: "ws", path: $path} + (if $host != "" then {headers: {Host: $host}} else {} end))}
           elif $net == "grpc" then
             (if $path != "" then $path else $host end) as $sn
             | {transport: ({type: "grpc"} + (if $sn != "" then {service_name: $sn} else {} end))}
           elif $net == "h2" then
             {transport: ({type: "http"} + (if $path != "" then {path: $path} else {} end) + (if $host != "" then {host: [$host]} else {} end))}
           elif $net == "httpupgrade" then
             (if $host != "" then $host else $sni end) as $h
             | {transport: ({type: "httpupgrade", path: (if $path == "" then "/" else $path end)} + (if $h != "" then {host: $h} else {} end))}
           elif ($net == "tcp" or $net == "") then {}
           else null end) as $tr
          | if $tr == null then {s: "slow"} else
            (if ($tls == "tls" or $tls == "1" or $tls == "true" or $net == "h2") then
               (if $sni != "" then $sni else $server end) as $sn
               | {enabled: true}
                 + (if $sn != "" then {server_name: $sn} else {} end)
                 + (if $alpn != "" then {alpn: ($alpn | split(","))} else {} end)
                 + (if $fp != "" then {utls: {enabled: true, fingerprint: $fp}} else {} end)
             else {} end) as $tlsb
            | {s: "ok", name: $name,
               ob: ({type: "vmess", server: $server, server_port: ($port | tonumber), uuid: $uuid, security: (if $scy != "" then $scy else "auto" end)}
                    + (if $aid != "" and $aid != "0" then {alter_id: ($aid | tonumber)} else {} end)
                    + (if ($tlsb | length) > 0 then {tls: $tlsb} else {} end)
                    + $tr)}
          end
      end
    end
  end;

def convert($opt):
  if startswith("vmess://") then vmess_convert(.; $opt) else
  parse_link as $l
  | if $l == null or ($l.host | contains("%")) then {s: "slow"} else
    ($l.ui | pdecode) as $userinfo
    | ($l.frag | if contains("+") then (split("+") | join(" ")) else . end | pdecode) as $name
    | $l.pairs as $pairs
    | $l.host as $host
    | $l.port as $port
    | $l.scheme as $scheme
    | if $userinfo == null or $name == null or ($port | is_digits | not) or ($port | length) > 5 or ($port | startswith("0")) then {s: "slow"}
      elif $scheme == "vless" then
        qv($pairs; "encryption"; true) as $enc
        | qv($pairs; "flow"; false) as $flow
        | qv($pairs; "packetEncoding"; false) as $pe
        | tls_block($pairs; $opt; false) as $tls
        | transport_block($pairs) as $tr
        | if $userinfo == "" or $enc == null or ($enc != "" and $enc != "none") or $flow == null or $pe == null or $tls == null or $tr == null then {s: "slow"}
          else {s: "ok", name: $name,
                ob: ({type: "vless", server: $host, server_port: ($port | tonumber), uuid: $userinfo}
                     + (if $flow != "" then {flow: $flow} else {} end)
                     + (if $pe != "" then {packet_encoding: $pe} else {} end)
                     + (if ($tls | length) > 0 then {tls: $tls} else {} end)
                     + $tr)} end
      elif $scheme == "trojan" then
        tls_block($pairs; $opt; true) as $tls
        | transport_block($pairs) as $tr
        | if $userinfo == "" or $tls == null or $tr == null then {s: "slow"}
          else {s: "ok", name: $name,
                ob: ({type: "trojan", server: $host, server_port: ($port | tonumber), password: $userinfo}
                     + (if ($tls | length) > 0 then {tls: $tls} else {} end)
                     + $tr)} end
      elif ($scheme == "hysteria2" or $scheme == "hy2") then
        qv($pairs; "obfs"; false) as $obfs
        | qv($pairs; "obfs-password"; false) as $obfspw
        | qv($pairs; "upmbps"; false) as $up
        | qv($pairs; "downmbps"; false) as $down
        | tls_block($pairs; $opt; true) as $tls0
        | if ($opt.quic | not) or $userinfo == "" or $tls0 == null
             or ([$obfs, $obfspw, $up, $down] | any(. == null))
             or ($up != "" and ($up | is_digits | not)) or ($down != "" and ($down | is_digits | not))
             or ($pairs | any(.[0] == "ports" or .[0] == "mport")) or ($l.port | contains(",")) or ($l.port | contains("-"))
          then {s: "slow"}
          else ($tls0 | del(.utls)) as $tls
               | {s: "ok", name: $name,
                  ob: ({type: "hysteria2", server: $host, server_port: ($port | tonumber), password: $userinfo}
                       + (if $obfs != "" and $obfspw != "" then {obfs: {type: $obfs, password: $obfspw}} else {} end)
                       + (if $up != "" then {up_mbps: ($up | tonumber)} else {} end)
                       + (if $down != "" then {down_mbps: ($down | tonumber)} else {} end)
                       + (if ($tls | length) > 0 then {tls: $tls} else {} end))} end
      elif $scheme == "ss" then
        # "method:password" as it is, or the base64 of it; the method is before the first ":"
        ($userinfo | split(":")) as $up
        | (if $userinfo == "" or ($userinfo | contains("\n")) then null
           elif (($up | length) == 2 or ($up | length) == 3) and ($up | all(. != "")) then $userinfo
           # base64 without its padding is read differently by the slow path: left to it
           elif (($userinfo | length) % 4) != 0 then null
           else ($userinfo | b64text) end) as $mp
        | if $mp == null or ($mp | contains(":") | not) then {s: "slow"}
          else {s: "ok", name: $name,
                ob: {type: "shadowsocks", server: $host, server_port: ($port | tonumber),
                     method: ($mp | split(":")[0]), password: ($mp | split(":")[1:] | join(":"))}
                     + (if $opt.udp_over_tcp == "1" then {udp_over_tcp: {enabled: true, version: 2}} else {} end)} end
      elif $scheme == "socks5" then
        # as the slow path cuts it: the user before the first ":" (all of it without one),
        # the password after it (all of it without a ":" too)
        ($userinfo | split(":")) as $up
        | (if $userinfo == "" then "" else $up[0] end) as $user
        | (if $userinfo == "" then "" elif ($up | length) > 1 then ($up[1:] | join(":")) else $userinfo end) as $pass
        | {s: "ok", name: $name,
           ob: ({type: "socks", server: $host, server_port: ($port | tonumber), version: "5"}
                + (if $user != "" then {username: $user} else {} end)
                + (if $pass != "" then {password: $pass} else {} end)
                + (if $opt.udp_over_tcp == "1" then {udp_over_tcp: {enabled: true, version: 2}} else {} end))}
      else {s: "slow"} end
  end
  end;

# One result per input line, in order, read as a stream: the lines of a big feed are never
# held in memory together. "i" is the number of the link in the list ($opt.base is the
# number of the first one of this run).
foreach inputs as $line ($opt.base; . + 1;
  # a link that makes the program stumble is a slow one, not a failure of the whole run
  (try ($line | convert($opt)) catch {s: "slow"}) + {i: (. - 1)})
