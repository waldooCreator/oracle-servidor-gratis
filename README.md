# Servidor gratis en Oracle Cloud

Cada hora, GitHub Actions intenta crear un servidor Ampere A1 (Always Free) en Oracle Cloud hasta que haya cupo.
Prueba primero 4 OCPU / 24 GB, luego 2/12 y luego 1/6. Cuando lo logra abre un issue para avisar y se apaga sola.

Las credenciales viven en los Secrets del repositorio; aquí no hay ninguna.
