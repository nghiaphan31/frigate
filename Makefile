SOT=sot/sot.yaml

.PHONY: validate generate-dns
validate:
	python3 tools/validate.py $(SOT)

generate-dns:
	python3 tools/export_coredns.py $(SOT) -o out/coredns

