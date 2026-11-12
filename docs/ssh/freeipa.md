# Совмещение с FreeIPA

!!! danger "Прочитайте до начала работ"
    Если на сервере уже настроен FreeIPA, а вы просто добавите строку Alatyr в
    настройки `sshd`, одна из двух схем перестанет работать — и ничего об
    этом не скажет.


У `sshd` одна директива `AuthorizedKeysCommand` **на область**, и вторую в той
же области он молча пропускает: сработает первая по порядку, вторая не
выполнится ни разу и ничего об этом не скажет.

Если FreeIPA уже настроен глобально, объявите команду Alatyr **для отдельной
области** через `Match`, а глобально оставьте только строки сертификатов:

```
# /etc/ssh/sshd_config.d/00-alatyr.conf — читается раньше файлов FreeIPA
TrustedUserCAKeys               /etc/ssh/alatyr_user_ca.pub
AuthorizedPrincipalsCommand     /usr/local/sbin/alatyr-keyholder-get.sh principals principal=%u serial=%s
AuthorizedPrincipalsCommandUser alatyr-kh

# глобально — то, что настроил ipa-client-install
AuthorizedKeysCommand     /usr/bin/sss_ssh_authorizedkeys
AuthorizedKeysCommandUser nobody

# наши учётные записи — источник Alatyr; блок Match — в конце sshd_config
Match User svc-deploy,svc-backup
    AuthorizedKeysCommand     /usr/local/sbin/alatyr-keyholder-get.sh keys principal=%u format=text
    AuthorizedKeysCommandUser alatyr-kh
```

Сертификаты (`TrustedUserCAKeys`) с FreeIPA не конфликтуют вовсе — это
отдельный механизм, его можно включить сразу и глобально. Только
`AuthorizedPrincipalsCommand` должна стоять **раньше любой**
`AuthorizedKeysCommand`, включая строки FreeIPA, — почему, сказано в
[настройке, шаг 5](setup.md#настройка-sshd). Скрипт
`alatyr-keyholder-get.sh`, учётная запись `alatyr-kh` и каталог
`/run/alatyr-kh` — оттуда же.


## Как проверить, что получилось

```bash
sudo sshd -T | grep -i authorizedkeyscommand
```

Команда печатает действующую настройку. Если вы ждали команду Alatyr, а видите
чужую — сработала не та директива, и вход по ключам Alatyr не пройдёт.

Внутри блока `Match` проверяйте с указанием учётной записи:

```bash
sudo sshd -T -C user=svc-deploy,host=localhost,addr=127.0.0.1 | grep -i authorizedkeyscommand
```

## Что дальше

- [Настройка](setup.md) — остальные шаги, если вы сюда пришли из неё.
- [Нюансы и пределы](caveats.md) — другие места, где механизм ведёт себя
  не так, как ожидается.
