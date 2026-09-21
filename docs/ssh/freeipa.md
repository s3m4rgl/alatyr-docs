# Совмещение с FreeIPA

!!! danger "Прочитайте до начала работ"
    Если на сервере уже настроен FreeIPA, а вы просто добавите строку Alatyr в
    настройки `sshd`, одна из двух схем перестанет работать — и ничего об
    этом не скажет.


У `sshd` одна директива `AuthorizedKeysCommand` **на область**, и вторую в той
же области он молча пропускает: сработает первая по порядку, вторая не
выполнится ни разу и ничего об этом не скажет.

Если FreeIPA уже настроен глобально, объявите команду Alatyr **для отдельной
области** через `Match`:

```
# глобально — то, что настроил ipa-client-install
AuthorizedKeysCommand     /usr/bin/sss_ssh_authorizedkeys
AuthorizedKeysCommandUser nobody

# наши учётные записи — источник Alatyr
Match User svc-deploy,svc-backup
    AuthorizedKeysCommand     /etc/ssh/alatyr-keys.sh
    AuthorizedKeysCommandUser root
```

Сертификаты (`TrustedUserCAKeys`) с FreeIPA не конфликтуют вовсе — это
отдельный механизм, его можно включить сразу и глобально.


## Как проверить, что получилось

```bash
sudo sshd -T | grep -i authorizedkeyscommand
```

Команда печатает действующую настройку. Если вы ждали команду Alatyr, а видите
чужую — сработала не та директива, и вход по ключам Alatyr не пройдёт.

Внутри блока `Match` проверяйте с указанием учётной записи:

```bash
sudo sshd -T -C user=svc-deploy | grep -i authorizedkeyscommand
```

## Что дальше

- [Настройка](setup.md) — остальные шаги, если вы сюда пришли из неё.
- [Нюансы и пределы](caveats.md) — другие места, где механизм ведёт себя
  не так, как ожидается.
