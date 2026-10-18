# Twinshot — план реализации

Гем для 1:1-парити двух деревьев артефактов: оракул (verified) vs текущее
состояние. Структура папок свободная, но должна совпасть. Любой файл без
адаптера — фейл. Отчёт — самодостаточный HTML с 1:1-галереей (как текущий
`artifacts/compare/report.html` в capybara-tests) + поиск, фильтры, режимы
сравнения картинок. В хорошем случае команды генерации не нужны — compare
берёт две готовые папки.

## Конфиг (`twinshot.yml`, минимальный)

```yaml
oracle:
  path: artifacts/rails
  generate: bin/record          # опционально
current:
  path: artifacts/crails
  generate: bin/record --crails # опционально
png:
  max_diff_ratio: 0.002         # опционально, дефолт 0.002
```

Отчёт всегда пишется в `<dirname(config)>/twinshot-report/`
(`report_for_human.html` + `report_for_agent.md` + `summary.json` +
`diffs/*`). Не настраивается.

## Структура кода

```
lib/twinshot.rb               — точка входа, requires
lib/twinshot/cli.rb           — OptionParser: help / generate / compare
lib/twinshot/config.rb        — загрузка + валидация twinshot.yml
lib/twinshot/tree.rb          — скан дерева, сверка структуры
lib/twinshot/adapters.rb      — реестр адаптеров по расширению
lib/twinshot/adapters/binary.rb — sha256, побайтово
lib/twinshot/adapters/txt.rb    — построчный diff (diff-lcs)
lib/twinshot/adapters/html.rb   — по структуре: nokogiri-канонизация → построчный diff
lib/twinshot/adapters/png.rb    — байты fast-path → попиксельно (chunky_png) + diff-картинка
lib/twinshot/compare.rb       — оркестратор: структура → файлы в пуле форк-воркеров
lib/twinshot/report.rb        — HTML-отчёт (инлайн CSS/JS, без зависимостей)
exe/twinshot
```

## Правила сравнения

1. **Структура**: дерево файлов `current` обязано совпадать с `oracle` 1:1.
   Лишний файл / недостающий / пустая папка в стороне — фейл-запись в отчёт.
2. **Файлы**: адаптер по расширению. Нет адаптера → фейл («no adapter for .xyz»).
3. PNG: байты равны → pass; иначе попиксельно, pass если diff-доля ≤
   `max_diff_ratio`; при несовпадении размеров — фейл с указанием размеров.
   Для провала генерится `diffs/<rel>.diff.png` (изменённые пиксели красным).
4. HTML: канонизация DOM (nokogiri: убрать комментарии, схлопнуть пробелы в
   текст-нодах, отсортировать атрибуты, сериализовать построчно) → построчный
   diff. Pass = 0 расхождений.
5. TXT: построчный diff (diff-lcs). Pass = 0 расхождений.
6. Бинарные (зарегистрированные как binary): sha256.

## Параллелизм

Структура — синхронно (дёшево). Файлы — пул форк-воркеров (`--jobs N`,
дефолт = число ядер, кап 8): round-robin срезы, результаты пишутся воркерами
в tmpdir как JSON, родитель мёржит и сортирует. `--jobs 1` — последовательно.
Форки вместо Ractors: совместимо с 3.2+ и без GVL-проблем chunky_png.

## CLI

```
twinshot help [COMMAND]                — справка
twinshot generate oracle|current       — запускает generate-команду из конфига (chdir = dirname конфига)
twinshot compare                       — сравнивает две папки, пишет отчёт
  -c, --config PATH   (default: twinshot.yml)
  -j, --jobs N
      --json           — machine-итог в stdout
  -V, --version
```

Exit-коды: 0 — всё сошлось; 1 — есть расхождения; 2 — ошибка конфига/usage.

## Отчёт

- Группировка по папкам (заголовок группы + счётчик), внутри провалы первыми.
- Sticky-шапка: итоги, поиск по подстроке имени, фильтры все/провалы/прошедшие,
  режимы картинок: рядом / слайдер / мигание.
- Sticky-имя файла над каждой парой (как в текущем отчёте capybara-tests).
- Клавиши n/p — прыжок к следующему/предыдущему видимому шоту.
- Текстовые диффы инлайном (`+/-` строки, кап 400 строк).
- Всё инлайн (CSS/JS), внешних ассетов нет; картинки — относительные пути.

## Тесты (minitest)

- config: загрузка, дефолты, ошибки валидации
- tree: совпадение/лишний/недостающий файл
- adapters: binary/txt/png (мини-PNG генерим chunky_png)/html-канонизация/unknown ext
- compare: e2e на tmp-деревьях, включая fork-пул (jobs 1 и 2)
- cli: help, unknown command, exit-коды
- report: генерится, содержит маркеры групп/шотов

## Интеграция

`capybara-tests/twinshot.yml` → `oracle: artifacts/rails`, `current: artifacts/crails`,
запуск `twinshot compare`, проверка exit-кода, отчёта и summary.json на живых данных
(127 файлов rails, 129 crails — есть реальный лишний файл для проверки структуры).

## Готовность

rake test зелёный, rake build собирается, на capybara-артефактах compare
возвращает ненулевой exit (лишний файл), отчёт открывается и работает.
