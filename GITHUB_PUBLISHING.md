# Публикация новой версии на GitHub

Репозиторий: <https://github.com/Plyshkaa/change-geo-ios>.

Публичная история проекта использует GitHub noreply-адрес. Готовые приложения
публикуются как файлы GitHub Release; каталоги `build/` и `dist/` не нужно
добавлять в Git.

## 1. Обновить версию

Перед выпуском синхронно измените номер версии в:

- `Info.plist`: `CFBundleShortVersionString` и `CFBundleVersion`;
- `pyproject.toml`;
- `User-Agent` резервного маршрутизатора в `LocationControllerApp.swift`.

## 2. Проверить автора и исходники

```shell
cd ~/geo-ios
git config --get user.name
git config --get user.email
git status --short
git diff --check
```

Для этого репозитория ожидается noreply-адрес:

```text
72494478+Plyshkaa@users.noreply.github.com
```

Проверьте отсутствие секретов:

```shell
git ls-files | rg -i '(^|/)(\.env|.*\.(p12|p8|key|pem|mobileprovision|cer))$'
rg --hidden --glob '!.git/**' --glob '!.venv/**' --glob '!build/**' \
  --glob '!dist/**' -n \
  -e 'BEGIN .*PRIVATE KEY' -e 'ghp_[A-Za-z0-9]+' \
  -e 'github_pat_[A-Za-z0-9_]+' -e 'sk-[A-Za-z0-9]+'
```

Результат должен быть пустым либо содержать только эти примеры из
документации.

## 3. Собрать и проверить приложение

```shell
cd ~/geo-ios
.venv/bin/python -m pip install -e '.[portable]'
./package_portable.sh
unzip -tq dist/iOS-Location-Controller-macOS-arm64.zip
cd dist
shasum -a 256 -c iOS-Location-Controller-macOS-arm64.zip.sha256
```

Последняя команда должна вывести
`iOS-Location-Controller-macOS-arm64.zip: OK`. ZIP и его SHA-256 могут
изменяться при каждой пересборке. Публикуйте только одновременно созданную и
проверенную пару файлов.

## 4. Зафиксировать исходники

```shell
cd ~/geo-ios
git add .gitignore GITHUB_PUBLISHING.md Info.plist LICENSE \
  LocationControllerApp.swift README.md RUN_ON_ANOTHER_MAC.md \
  SECURITY_AUDIT.md SOURCE_OFFER.txt build_macos_app.sh example-route.gpx \
  generate_third_party_notices.py locationctl.py package_portable.sh \
  pyproject.toml run_locationctl.sh third_party_license_overrides \
  third_party_sources
git diff --cached --check
git diff --cached --stat
git commit -m "Release iOS Location Controller VERSION"
git push origin main
```

Замените `VERSION` фактической версией. Перед commit убедитесь, что среди
staged-файлов нет `.venv/`, `build/`, `dist/`, `.DS_Store`, ключей или
сертификатов.

## 5. Создать тег

Тег должен указывать на уже отправленный и проверенный commit:

```shell
git status --short
git tag -a vVERSION -m "iOS Location Controller vVERSION"
git push origin vVERSION
```

Не перемещайте и не переиспользуйте опубликованные теги для другого
содержимого.

## 6. Создать GitHub Release

На GitHub откройте **Releases → Draft a new release**:

1. Выберите созданный тег.
2. Укажите название `iOS Location Controller vVERSION`.
3. Прикрепите `iOS-Location-Controller-macOS-arm64.zip` и одноимённый
   `.sha256`.
4. Сначала сохраните draft и перепроверьте файлы.
5. Нажмите **Publish release**.

Рекомендуемый текст:

```text
Portable-сборка iOS Location Controller для Apple Silicon и macOS 13+.

Предназначена для тестирования собственных приложений на собственном iPhone с
включённым Developer Mode. После теста используйте «Сбросить на реальное гео».

Сборка имеет ad-hoc-подпись и не нотарифицирована Apple, поэтому macOS может
показать предупреждение при первом запуске. Проверьте ZIP по приложенному
SHA-256 перед открытием.

В архив включены исходники этой версии, лицензии сторонних компонентов и
исходные архивы GPL/LGPL-зависимостей.

Программа предоставляется «как есть» без гарантий. Пользователь отвечает за
соблюдение законодательства и правил сервисов, в которых она применяется.
```

## 7. Проверить опубликованный файл

Скачайте ZIP и `.sha256` из Release в новую папку:

```shell
cd ~/Downloads
shasum -a 256 -c iOS-Location-Controller-macOS-arm64.zip.sha256
unzip -tq iOS-Location-Controller-macOS-arm64.zip
```

После этого проверьте запуск на другом Mac и кнопку сброса с тестовым iPhone.

## Нотарификация

Для публичного приложения предпочтительны сертификат **Developer ID
Application**, hardened runtime и нотарификация Apple. Ad-hoc-подпись
проверяет целостность локального архива, но не подтверждает личность автора и
не обеспечивает обычный запуск через Gatekeeper после скачивания.
