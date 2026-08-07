#!/bin/zsh
cd "$(dirname "$0")"
out=cicese_xml
for st in bla snq ens lto; do
  for yy in 25 26; do
    for mm in 01 02 03 04 05 06 07 08 09 10 11 12; do
      target="$out/${st}${yy}${mm}.xml"
      [ -s "$target" ] && continue
      tmp="/tmp/_cic_${st}${yy}${mm}.pdf"
      code=$(curl -s -o "$tmp" -w "%{http_code}" "https://predmar.cicese.mx/calmen/pdf/${st}/${st}${yy}${mm}.pdf")
      sz=$(wc -c < "$tmp" 2>/dev/null || echo 0)
      if [ "$code" = "200" ] && [ "$sz" -gt 10000 ]; then
        pdftotext -bbox "$tmp" "$target" 2>/dev/null && echo "ok   ${st}${yy}${mm}" || echo "FAIL-extract ${st}${yy}${mm}"
      else
        echo "FAIL-fetch ${st}${yy}${mm} http=$code size=$sz"
      fi
      rm -f "$tmp"
      sleep 1
    done
  done
done
echo "DONE: $(ls -1 $out/*.xml 2>/dev/null | wc -l) files"
