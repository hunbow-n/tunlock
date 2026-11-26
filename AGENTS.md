# Работа с Tunlock

Этот файл задаёт правила работы с репозиторием для людей и агентов.
Пользовательские сценарии описаны в [README](README.ru.md), приёмка сетевой
защиты — в [docs/TESTING.md](docs/TESTING.md), публикация и проверка релизов —
в [docs/RELEASES.md](docs/RELEASES.md).

## Issue, ветка и PR

1. Для самостоятельной задачи используйте существующий issue или подготовьте
   карточку по [шаблону](.github/ISSUE_TEMPLATE/). Опишите проблему, область
   изменений, проверяемые критерии приёмки и зависимости со ссылками на issue.
   Перед работой проверьте статус блокеров. Для планирования укажите
   примерный размер задачи в карточке, если он влияет на очерёдность.
   Большую задачу разбейте на части, которые можно принять отдельно.
   Небольшую правку по прямому запросу можно выполнить локально без
   отдельной карточки.
2. Для задачи с issue используйте одну ветку `issue-<N>-<slug>` и один PR.
   Обновите `origin/main`, создайте ветку через
   `git switch --no-track -c issue-<N>-<slug> origin/main` и убедитесь, что
   upstream не задан. Другую базу согласуйте и укажите в PR. Сохраните
   посторонние изменения в рабочем дереве. Попутные находки вынесите отдельно.
3. Заполните [шаблон PR](.github/pull_request_template.md). Привяжите PR
   к issue строкой `Closes #N` в описании: GitHub покажет связь в обоих
   и закроет issue после merge в ветку по умолчанию. `Refs #N` не создаёт
   привязку. Если PR выполняет задачу не полностью, до merge вынесите
   остаток в новый issue со ссылкой на исходный и укажите это в PR.
   Опишите решения, отклонения от задачи и фактические результаты проверок.
4. Владелец принимает решение о merge после ревью и зелёного CI. Агент
   публикует issue и PR, создаёт или меняет коммиты, пушит, мержит,
   ставит теги и публикует релизы только по явному разрешению на каждое
   действие в рамках задачи. При разрешённом push укажите remote и ветку
   явно. Merge в `main` может запустить автоматический релиз.
5. Для исследования (spike) зафиксируйте в issue варианты, результаты,
   ограничения и вывод. Если решение задаёт долговременное правило проекта,
   обновите соответствующий документ в `docs/`. Реализацию оформите
   отдельной задачей, когда она нужна.
6. После merge в ветку по умолчанию проверьте по GitHub, закрылся ли
   связанный issue. Если он открыт, укажите причину или сообщите, что
   причину ещё нужно выяснить. Для релизного изменения проверьте завершение
   workflow и появление релиза по [инструкции](docs/RELEASES.md).

## Код и контракты

| Область | Где смотреть |
| --- | --- |
| CLI, конфигурация, сторож, правила PF | `bin/tunlock`, `tunlock.conf.example` |
| Установка, фоновые службы и сон | `install.sh`, `uninstall.sh`, `launchd/`, `app/Helpers/` |
| Приложение и MCP | `app/Sources/Tunlock/`, в том числе `Backend.swift`, `MCP.swift` и `L10n.swift` |
| Сборка и релиз | `build-app.sh`, `.github/workflows/macos.yml`, `docs/RELEASES.md` |

- Следуйте существующим соглашениям Bash и Swift. Проверяйте совместимость
  с системным Bash на macOS, переиспользуйте текущий backend и тестовые
  заглушки. Новую зависимость обоснуйте в PR.
- Сохраняйте fail-closed поведение в защищённом режиме. При изменении
  сетевого пути проверьте затронутые сценарии SSH и proxy, подтверждение
  выхода и поведение при потере соединения. Сохраняйте изоляцию правил PF
  в anchor Tunlock. Изменение не должно редактировать `/etc/pf.conf` или
  перезагружать корневой набор правил.
- Конфигурация, предложенная через MCP, остаётся черновиком до подтверждения
  пользователем в приложении. Не добавляйте в код, логи, тестовые данные,
  issue и PR реальные ключи, токены, пароли и приватные настройки.
- Сохраняйте совместимость CLI, существующих конфигураций и MCP API.
  Согласованные несовместимые изменения требуют инструкции по миграции
  и отметки в коммите. При изменении пользовательского поведения обновите
  оба README и соответствующие английские и русские строки интерфейса.
- Issue и PR можно вести на русском или английском. Идентификаторы,
  комментарии в коде и сообщения коммитов пишите на английском.

## Проверка и готовность

| Изменение | Проверки |
| --- | --- |
| CLI, сторож, конфигурация | `bash tests/run.sh` без sudo. Для регрессии используйте существующие fixtures и stubs |
| SwiftUI или MCP | `bash build-app.sh` и для MCP `bash tests/mcp.sh build/Tunlock.app/Contents/MacOS/Tunlock`. Для модели конфигурации есть `bash tests/swift-model.sh` |
| Правила PF | Тесты с заглушками, `tests/pf-syntax.sh` для разбора правил с правами root и job `pf-live` в CI |
| Утечки и переходы защиты | Затронутые сценарии из [docs/TESTING.md](docs/TESTING.md) на реальном Mac с отдельным разрешением на изменения активной защиты |

`tests/pf-live.sh` рассчитан на одноразовый раннер GitHub Actions. При
приёмке перечислите команды, результаты и пропуски. Проверка синтаксиса PF
или тест с заглушками не подтверждает отсутствие утечек. Если IPv6 или
другой сценарий пропущен, укажите это отдельно.

Задача готова, когда выполнены критерии приёмки, пройдены применимые
проверки, обновлена затронутая документация, а в PR описаны фактические
результаты и ограничения. Перед merge дождитесь результатов `build` и
`pf-live` в [CI](.github/workflows/macos.yml).

При передаче работы укажите issue и ветку, изменённые области, результаты
проверок и оставшиеся шаги. Уточните, где находится результат: в рабочем
дереве, в коммите, в открытом PR или уже в релизе.

## Сообщения коммитов и версии

Use Conventional Commits for new commits and for the final squash commit
that will land on `main`. Write the subject as `type(scope): description`
in English, with a short imperative description. The scope is optional.
Choose the type based on what changes for users.

| Type | Use | Release bump |
| --- | --- | --- |
| `fix:` | Fix behavior without breaking compatibility | Patch |
| `perf:` | Improve performance without breaking compatibility | Patch |
| `feat:` | Add a compatible feature | Minor |
| `docs:`, `test:`, `ci:`, `build:`, `refactor:`, `chore:`, `style:` | Maintain the project without a user-facing release | None |

Mark incompatible changes to the CLI, config, or MCP API with
`BREAKING CHANGE: <what breaks and how to migrate>` on one line in the
footer. You can also add `!` before the colon to flag the subject.
Breaking changes bump the minor version while Tunlock is on `0.x`
and the major version from `1.0.0` onward. Moving from `0.x` to `1.0.0` is
an explicit release decision.

### Examples

```text
fix(pf): clear stale states when the exit changes
feat(proxy): add saved proxy profiles
ci(release): verify the packaged checksum
```

```text
feat(config)!: replace EXPECTED_EGRESS with EXIT_IP

BREAKING CHANGE: Rename EXPECTED_EGRESS to EXIT_IP in tunlock.conf before upgrading.
```

See [release workflow and verification](docs/RELEASES.md).
