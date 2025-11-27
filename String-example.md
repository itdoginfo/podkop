## Socks
```
socks4://127.0.0.1:1080
socks4a://127.0.0.1:1080
socks5://127.0.0.1:1080
socks5://username:password@127.0.0.1:1080
```

## Shadowsocks
```
ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206ZG1DbHkvWmgxNVd3OStzK0dGWGlGVElrcHc3Yy9xQ0lTYUJyYWk3V2hoWT0@127.0.0.1:25144?type=tcp#shadowsocks-no-client
ss://MjAyMi1ibGFrZTMtYWVzLTI1Ni1nY206S3FiWXZiNkhwb1RmTUt0N2VGcUZQSmJNNXBXaHlFU0ZKTXY2dEp1Ym1Fdz06dzRNMEx5RU9OTGQ5SWlkSGc0endTbzN2R3h4NS9aQ3hId0FpaWlxck5hcz0@127.0.0.1:26627?type=tcp#shadowsocks-client
ss://2022-blake3-aes-256-gcm:dmCly/Zh15Ww9+s+GFXiFTIkpw7c/qCISaBrai7WhhY=@127.0.0.1:27214?type=tcp#shadowsocks-plain-user
```

## VLESS
```
# tcp
vless://94792286-7bbe-4f33-8b36-18d1bbf70723@127.0.0.1:34520?type=tcp&encryption=none&security=none#vless-tcp-none
vless://e95163dc-905e-480a-afe5-20b146288679@127.0.0.1:16399?type=tcp&encryption=none&security=reality&pbk=tqhSkeDR6jsqC-BYCnZWBrdL33g705ba8tV5-ZboWTM&fp=chrome&sni=google.com&sid=f6&spx=%2F#vless-tcp-reality
vless://2e9e8288-060e-4da2-8b9f-a1c81826feb7@127.0.0.1:19316?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-tcp-tls
vless://0235c833-dc29-4202-8a7b-1bbba5b516a2@127.0.0.1:22993?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#vless-tcp-tls-insecure
vless://17776137-e747-4268-a84d-99fd798accac@127.0.0.1:48076?type=tcp&encryption=none&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com&ech=AFP%2BDQBPAAAgACDJXiKG5eoCHfd1MbMxgccxgrbGisBPPe3bz1KVIETUXQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAAAAAA%3D%3D#vless-tcp-tls-ech

# mKCP
vless://72e201d7-7841-4a32-b266-4aa3eb776d51@127.0.0.1:17270?type=kcp&encryption=none&headerType=none&seed=AirziWi4ng&security=none#vless-mKCP

# WebSocket
vless://d86daef7-565b-4ecd-a9ee-bac847ad38e6@127.0.0.1:12928?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=none#vless-websocket-none
vless://fe0f0941-09a9-4e46-bc69-e00190d7bb9c@127.0.0.1:10156?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-websocket-tls
vless://599e8659-e2ef-47d9-bf72-2f9b4b673474@127.0.0.1:36567?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#vless-websocket-tls-insecure
vless://4d21ce62-8723-4c4d-93e3-d586b107aa40@127.0.0.1:51394?type=ws&encryption=none&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com&ech=AF3%2BDQBZAAAgACD7fjrtDMlcigKXFBKoLn6UDB9%2BWR6HBZpY96DlBiD%2BIwAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D#vless-websocket-tls-ech

# gRPC
vless://974b39e3-f7bf-42b9-933c-16699c635e77@127.0.0.1:15633?type=grpc&encryption=none&serviceName=TunService&authority=&security=none#vless-gRPC-none
vless://651e7eca-5152-46f1-baf2-d502e0af7b27@127.0.0.1:28535?type=grpc&encryption=none&serviceName=TunService&authority=authority&security=reality&pbk=nhZ7NiKfcqESa5ZeBFfsq9o18W-OWOAHLln9UmuVXSk&fp=chrome&sni=google.com&sid=11cbaeaa&spx=%2F#vless-gRPC-reality
vless://221ff905-b783-41a0-a6a6-8089eaf3b34b@abc.def.xyz:443?security=reality&type=grpc&headerType=&authority=abc.def.xyz&serviceName=name&mode=gun&sni=abc.def.xyz&fp=chrome&pbk=C3nhDJw02ZU_rjx4GbC54Sp79-ysF5lWIQVWdY4FOnE&sid=#vless-gRPC-reality-mode
vless://af1f8b5f-26c9-4fe8-8ce7-6d6366c5c9ce@127.0.0.1:47904?type=grpc&encryption=none&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-gRPC-tls
vless://95f2c4bb-abcb-47ba-bfad-e181c03e4659@127.0.0.1:34530?type=grpc&encryption=none&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#vless-gRPC-tls-insecure
vless://bd39490f-9a4f-49b2-96b6-824190cf89e9@127.0.0.1:27779?type=grpc&encryption=none&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com&ech=AF3%2BDQBZAAAgACBc%2FiNdo4QkTt9eQCQgkOiJVSfA9G6UWAyipaBFtBD%2FVQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D#vless-gRPC-tls-ech

# HTTPUpgrade
vless://2b98f144-847f-42f7-8798-e1a32d27bdc7@127.0.0.1:47154?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=none#vless-httpupgrade-none
vless://76dbd0ff-1a35-4f0c-a9ba-3c5890b7dea6@127.0.0.1:50639?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#vless-httpupgrade-tls
vless://6d229881-50ed-4f3f-995d-bd3e725fdbff@127.0.0.1:57616?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#vless-httpupgrade-tls-insecure
vless://1897e9e4-6f5d-4a85-9512-9192e76c3f04@127.0.0.1:38658?type=httpupgrade&encryption=none&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com&ech=AF3%2BDQBZAAAgACCmXTMzlrdcCk2FyINAWKZ4DBxq4%2BCgmJ69v%2BmH4EMlEQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D#vless-httpupgrade-tls-ech

# XHTTP
vless://c2841505-ec32-4b8d-b6dd-3e19d648c321@127.0.0.1:45507?type=xhttp&encryption=none&path=%2Fxhttppath&host=xhttp&mode=auto&security=none#vless-xhttp
```

## Trojan
```
# tcp
trojan://04agAQapcl@127.0.0.1:33641?type=tcp&security=none#trojan-tcp-none
trojan://cME3ZlUrYF@127.0.0.1:43772?type=tcp&security=reality&pbk=DckTwU6p6pTX9QxFXOi6vH4Vzt_RCE1vMCnj2c6hvjw&fp=chrome&sni=google.com&sid=221a80cf94&spx=%2F#trojan-tcp-reality
trojan://EJjpAj02lg@127.0.0.1:11381?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-tcp-tls
trojan://ZP2Ik5sxN3@127.0.0.1:16247?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-tcp-tls-insecure
trojan://90caP481ay@127.0.0.1:59708?type=tcp&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACC2y%2BAe4dqthLNpfvmtE6g%2BnaJ%2FciK6P%2BREbRLkR%2Fg%2FEgAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-tcp-tls-ech

# mKCP
trojan://N5v7iIOe9G@127.0.0.1:36319?type=kcp&headerType=none&seed=P91wFIfjzZ&security=none#trojan-mKCP

# WebSocket
trojan://G3cE9phv1g@127.0.0.1:57370?type=ws&path=%2Fwspath&host=google.com&security=none#trojan-websocket-none
trojan://FBok41WczO@127.0.0.1:59919?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-websocket-tls
trojan://bhwvndUBPA@127.0.0.1:22969?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-websocket-tls-insecur
trojan://pwiduqFUWO@127.0.0.1:46765?type=ws&path=%2Fwspath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACCFcQYEtwrFOidJJLYHvSiN%2BljRgaAIrNHoVnio3uXAOwAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-websocket-tls-ech

# gRPC
trojan://WMR7qkKhsV@127.0.0.1:27897?type=grpc&serviceName=TunService&authority=authority&security=none#trojan-gRPC-none
trojan://KVuRNsu6KG@127.0.0.1:46077?type=grpc&serviceName=TunService&authority=authority&security=reality&pbk=Xn59i4gum3ppCICS6-_NuywrhHIVVAH54b2mjd5CFkE&fp=chrome&sni=google.com&sid=e5be&spx=%2F#trojan-gRPC-reality
trojan://7BJtbywy8h@127.0.0.1:10627?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-gRPC-tls
trojan://TI3PakvtP4@127.0.0.1:10435?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-gRPC-tls-insecure
trojan://mbzoVKL27h@127.0.0.1:38681?type=grpc&serviceName=TunService&authority=authority&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACCq72Ru3VbFlDpKttl3LccmInu8R2oAsCr8wzyxB0vZZQAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-gRPC-tls-ech

# HTTPUpgrade
trojan://uc44gBwOKQ@127.0.0.1:29085?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=none#trojan-httpupgrade-none
trojan://MhNxbcVB14@127.0.0.1:32700?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&sni=google.com#trojan-httpupgrade-tls
trojan://7SOQFUpLob@127.0.0.1:28474?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&allowInsecure=1&sni=google.com#trojan-httpupgrade-tls-insecure
trojan://ou8pLSyx9N@127.0.0.1:17737?type=httpupgrade&path=%2Fhttpupgradepath&host=google.com&security=tls&fp=chrome&alpn=h2%2Chttp%2F1.1&ech=AF3%2BDQBZAAAgACB%2FlkIkit%2BblFzE7PtbYDVF3NXK8olXJ5a7YwY%2Biy9QQwAkAAEAAQABAAIAAQADAAIAAQACAAIAAgADAAMAAQADAAIAAwADAApnb29nbGUuY29tAAA%3D&sni=google.com#trojan-httpupgrade-tls-ech

# XHTTP
trojan://VEetltxLtw@127.0.0.1:59072?type=xhttp&path=%2Fxhttppath&host=google.com&mode=auto&security=none#trojan-xhttp
```

## Hysteria2

hysteria2://
```
# With password
hysteria2://password@example.com:443/#hysteria2-password
hysteria2://password@example.com:443/?insecure=1#hysteria2-password-insecure

# With SNI
hysteria2://password@example.com:443/?sni=example.com#hysteria2-password-sni

# With obfuscation
hysteria2://password@example.com:443/?obfs=salamander&obfs-password=obfspassword#hysteria2-obfs

# All parameters combined
hysteria2://mypassword@example.com:8443/?sni=example.com&obfs=salamander&obfs-password=obfspass&insecure=1#hysteria2-all-params
```

hy2://
```
# With password
hy2://password@example.com:443/#hysteria2-password
hy2://password@example.com:443/?insecure=1#hysteria2-password-insecure

# With SNI
hy2://password@example.com:443/?sni=example.com#hysteria2-password-sni

# With obfuscation
hy2://password@example.com:443/?obfs=salamander&obfs-password=obfspassword#hysteria2-obfs

# All parameters combined
hy2://mypassword@example.com:8443/?sni=example.com&obfs=salamander&obfs-password=obfspass&insecure=1#hysteria2-all-params
```