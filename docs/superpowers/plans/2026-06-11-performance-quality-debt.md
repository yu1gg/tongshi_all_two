# 性能与代码质量债务治理 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 分阶段治理日期字段、字符串主键、类型约束、学生课程权限复用、无用前端 store、HTTP 错误语义、`format_project` 防御式格式化和内存限流膨胀问题。

**Architecture:** 先处理低风险且可回归验证的代码质量问题，再处理接口错误语义兼容，最后把数据库类型和主键改造拆成单独迁移阶段。数据库结构变更必须保持 MySQL 为正式目标、SQLite 为测试目标，并优先通过兼容层和测试保护现有数据。

**Tech Stack:** 后端 FastAPI + SQLAlchemy + Pydantic + pytest；前端 Vue 3 + TypeScript + Vite + Element Plus；数据库 MySQL，测试使用 SQLite 内存库。

---

## 背景与现状

本计划来自 2026-06-11 技术债清单，覆盖以下问题：

- `Material.date`、`Project.date`、`ActivityEvent.date` 使用 `String(32)` 存储日期，排序和查询依赖字符串。
- `User.id` 使用 `String(32)` 作为业务账号和主键，多表外键 JOIN 成本较高。
- `Material.type`、`Question.type`、以及部分状态字段缺少枚举约束，容易写入脏数据。
- `_student_can_access_course` 在多个 service 中重复定义。
- `frontend/src/stores/counter.ts` 是 Vite/Pinia 默认示例 store，当前无业务引用。
- `BusinessException` 等业务异常统一返回 HTTP 200，前端只能靠 body.code 判断错误。
- `project_service.format_project` 中大量 `hasattr`/`getattr` 暗示格式化输入边界不清。
- 忘记密码限流 `_FORGOT_FAILURES` 是进程内字典，只按单用户访问时清理，长时间运行会积累冷用户 key。

当前工作区已有大量未提交改动，且部分改动已经覆盖课程权限、作品范围、Schema 和测试文件。执行本计划时必须先确认这些改动是否属于已完成任务，禁止回滚或覆盖。

## 范围

本计划包含：

- 抽取学生课程访问判断为共享服务函数。
- 删除无引用的 `counter.ts` 并验证前端构建。
- 为 `Material.type`、`Question.type` 加 Pydantic 输入校验，并规划数据库 CHECK 约束。
- 为忘记密码限流字典增加全局清理机制。
- 收敛 `format_project` 的输入类型和预加载策略，减少 `hasattr` 防御。
- 设计 HTTP 错误状态码兼容迁移方案。
- 设计日期字段和用户主键的数据库迁移路线。

本计划暂不直接实施：

- 不在一个阶段内把 `User.id` 从字符串主键改为整型主键。这是全库外键迁移，必须单独设计、备份、回滚和验收。
- 不一次性修复全项目历史乱码注释或文案。只允许修改当前任务直接涉及的新增或变更文案。
- 不改变统一响应体 `{"code": ..., "data": ..., "message": ...}` 的形状。即使 HTTP 状态码改为真实状态，也保留响应体格式以兼容前端。
- 不引入 Redis 限流。Redis 属于多人部署扩容计划范围，本计划只修复当前进程内字典膨胀。

## 风险分级

- 低风险：删除 `counter.ts`、抽取权限函数、补充 Pydantic 枚举校验、限流字典清理。
- 中风险：`format_project` 收敛为明确 ORM 输入，并配合 `joinedload` 减少查询。
- 高风险：HTTP 错误状态码从 200 迁移为真实状态码，会影响前端拦截器和历史测试。
- 迁移级风险：日期列类型改造、`User.id` 主键改造，必须独立计划和数据库迁移脚本。

## 文件结构

- 新增：`backend/app/services/access_control_service.py`
  - 统一放置学生课程可访问判断，后续也可放教师课程归属判断。
- 修改：`backend/app/services/quiz_service.py`
  - 移除本地 `_student_can_access_course`，改用共享函数。
- 修改：`backend/app/services/project_service.py`
  - 如果仍存在重复学生课程判断，改用共享函数；收敛 `format_project` 输入。
- 修改：`backend/app/schemas/common.py`
  - 增加资料和题目类型校验。
- 修改：`backend/app/services/auth_service.py`
  - 给 `_FORGOT_FAILURES` 增加全局清理函数和测试辅助入口。
- 修改：`backend/main.py`
  - 在兼容阶段可用环境变量控制业务异常 HTTP 状态码。
- 修改：`frontend/src/api/http.ts`
  - 同时兼容 HTTP 非 2xx 与 body.code 非 0。
- 删除：`frontend/src/stores/counter.ts`
  - 删除无业务引用的默认示例 store。
- 新增或修改测试：
  - `backend/tests/test_access_control_service.py`
  - `backend/tests/test_type_validation.py`
  - `backend/tests/test_forgot_password_rate_limit.py`
  - `backend/tests/test_http_status_compat.py`
  - `frontend/tests/no-counter-store-static.test.mjs`

---

### Task 1: 执行前基线确认

**Files:**
- No source changes.

- [ ] **Step 1: 检查工作区已有改动**

Run:

```powershell
git status --porcelain=v1 -uall
```

Expected:

- 明确列出已有未提交文件。
- 如果有与本计划同名或同模块文件的未提交改动，先阅读这些文件，不覆盖。

- [ ] **Step 2: 检查关键问题仍然存在**

Run:

```powershell
rg -n "_student_can_access_course|date = Column\(String\(32\)|type = Column\(String\(16\)|_FORGOT_FAILURES|defineStore\('counter'|status_code=200" backend frontend
```

Expected:

- 能定位重复权限函数、字符串日期列、字符串类型列、限流字典、`counter.ts`、HTTP 200 异常处理。
- 若某项已被现有未提交改动修复，执行时把对应任务标记为已完成并补跑验证。

---

### Task 2: 统一学生课程访问判断

**Files:**
- Create: `backend/app/services/access_control_service.py`
- Modify: `backend/app/services/quiz_service.py`
- Modify: `backend/app/services/project_service.py`
- Test: `backend/tests/test_access_control_service.py`

- [ ] **Step 1: 写失败测试**

Create `backend/tests/test_access_control_service.py`:

```python
"""课程访问权限服务测试。"""

from app.services.access_control_service import student_can_access_course


def test_student_can_access_joined_course(db_session):
    assert student_can_access_course(db_session, "2025001", 1) is True


def test_student_cannot_access_unjoined_course(db_session):
    assert student_can_access_course(db_session, "2025001", 2) is False
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
py -m pytest backend\tests\test_access_control_service.py -q
```

Expected: FAIL，原因是 `app.services.access_control_service` 尚不存在。

- [ ] **Step 3: 新增共享服务**

Create `backend/app/services/access_control_service.py`:

```python
"""访问权限辅助服务。"""

from sqlalchemy.orm import Session

from app.models.entities import Class, StudentClassEnrollment


def student_can_access_course(db: Session, user_id: str, course_id: int) -> bool:
    """判断学生是否加入了课程对应的任一班级。"""
    return db.query(StudentClassEnrollment.id).join(
        Class,
        Class.id == StudentClassEnrollment.class_id,
    ).filter(
        StudentClassEnrollment.user_id == user_id,
        Class.course_id == course_id,
    ).first() is not None
```

- [ ] **Step 4: 替换重复实现**

Modify `backend/app/services/quiz_service.py`:

```python
from app.services.access_control_service import student_can_access_course
```

将调用点从：

```python
_student_can_access_course(db, user_id, question.course_id)
```

改为：

```python
student_can_access_course(db, user_id, question.course_id)
```

将课程统计处从：

```python
if not _student_can_access_course(db, user_id, course_id):
```

改为：

```python
if not student_can_access_course(db, user_id, course_id):
```

删除本地 `_student_can_access_course` 函数和不再使用的 `Class`、`StudentClassEnrollment` import。

如果 `backend/app/services/project_service.py` 中仍存在 `_student_can_submit_to_course` 且语义等同学生课程访问判断，将其替换为 `student_can_access_course`，保留函数名只在确实需要表达“提交作品”语义时作为薄封装：

```python
def _student_can_submit_to_course(db: Session, user_id: str, course_id: int) -> bool:
    return student_can_access_course(db, user_id, course_id)
```

- [ ] **Step 5: 验证无重复函数**

Run:

```powershell
rg -n "def _student_can_access_course|_student_can_access_course" backend\app\services
py -m pytest backend\tests\test_access_control_service.py backend\tests\test_student_course_visibility.py backend\tests\test_project_course_scope.py -q
```

Expected:

- `rg` 不再返回重复定义。
- 课程访问、作品课程范围相关测试通过。

---

### Task 3: 清理无用 counter store

**Files:**
- Delete: `frontend/src/stores/counter.ts`
- Create: `frontend/tests/no-counter-store-static.test.mjs`
- Modify: `frontend/package.json`

- [ ] **Step 1: 写静态测试**

Create `frontend/tests/no-counter-store-static.test.mjs`:

```js
import assert from 'node:assert/strict'
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const counterPath = resolve(root, 'src/stores/counter.ts')

function collectFiles(dir) {
  const result = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = resolve(dir, entry.name)
    if (entry.isDirectory()) {
      result.push(...collectFiles(full))
    } else if (/\.(ts|vue|mjs)$/.test(entry.name)) {
      result.push(full)
    }
  }
  return result
}

assert.equal(existsSync(counterPath), false, 'counter.ts 示例 store 应删除')

for (const file of collectFiles(resolve(root, 'src'))) {
  const content = readFileSync(file, 'utf8')
  assert.doesNotMatch(content, /stores\/counter|useCounterStore/, `${file} 不应引用 counter store`)
}
```

- [ ] **Step 2: 删除文件并补充脚本**

Delete `frontend/src/stores/counter.ts`。

Modify `frontend/package.json` scripts:

```json
"test:no-counter-store": "node ./tests/no-counter-store-static.test.mjs"
```

- [ ] **Step 3: 验证前端**

Run:

```powershell
npm run test:no-counter-store
npm run build
```

Working directory: `frontend`

Expected: 静态测试通过，前端构建通过。

---

### Task 4: 增加类型字段输入校验

**Files:**
- Modify: `backend/app/schemas/common.py`
- Test: `backend/tests/test_type_validation.py`

- [ ] **Step 1: 写失败测试**

Create `backend/tests/test_type_validation.py`:

```python
"""资料和题目类型校验测试。"""

import pytest
from pydantic import ValidationError

from app.schemas.common import AdminMaterialUpdate, AdminQuestionCreate, MaterialCreate, QuestionCreate


def test_material_type_allows_known_values():
    assert MaterialCreate(course_id=1, type="video", title="视频").type == "video"
    assert MaterialCreate(course_id=1, type="pdf", title="讲义").type == "pdf"
    assert AdminMaterialUpdate(type="link", title="链接").type == "link"


def test_material_type_rejects_unknown_value():
    with pytest.raises(ValidationError):
        MaterialCreate(course_id=1, type="bad", title="脏数据")


def test_question_type_allows_known_values():
    assert QuestionCreate(course_id=1, type="choice", stem="题干", answer="A").type == "choice"
    assert QuestionCreate(course_id=1, type="fill", stem="题干", answer="答案").type == "fill"
    assert AdminQuestionCreate(type="multi_choice", stem="题干", answer="AB").type == "multi_choice"


def test_question_type_rejects_unknown_value():
    with pytest.raises(ValidationError):
        QuestionCreate(course_id=1, type="essay", stem="题干", answer="答案")
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
py -m pytest backend\tests\test_type_validation.py -q
```

Expected: FAIL，未知类型当前不会被 Pydantic 拒绝。

- [ ] **Step 3: 加入校验器**

Modify `backend/app/schemas/common.py`，在 Schema 区域加入常量：

```python
MATERIAL_TYPES = {"video", "pdf", "link"}
QUESTION_TYPES = {"choice", "fill", "multi_choice"}
```

给 `MaterialCreate` 和 `AdminMaterialUpdate` 增加：

```python
    @field_validator("type")
    @classmethod
    def validate_type(cls, value: str) -> str:
        if value not in MATERIAL_TYPES:
            raise ValueError("资料类型必须为 video、pdf 或 link")
        return value
```

给 `QuestionCreate` 和 `AdminQuestionCreate` 增加：

```python
    @field_validator("type")
    @classmethod
    def validate_type(cls, value: str) -> str:
        if value not in QUESTION_TYPES:
            raise ValueError("题型必须为 choice、fill 或 multi_choice")
        return value
```

- [ ] **Step 4: 验证路由行为**

Run:

```powershell
py -m pytest backend\tests\test_type_validation.py backend\tests\test_integration_bugfixes.py -q
```

Expected: 类型校验测试通过；现有资料、题库、公共课程同步测试不回退。

---

### Task 5: 给限流字典增加全局清理

**Files:**
- Modify: `backend/app/services/auth_service.py`
- Test: `backend/tests/test_forgot_password_rate_limit.py`

- [ ] **Step 1: 写失败测试**

Create `backend/tests/test_forgot_password_rate_limit.py`:

```python
"""忘记密码限流内存清理测试。"""

from datetime import datetime, timedelta, timezone

from app.services import auth_service


def test_forgot_failure_cleanup_removes_expired_users(monkeypatch):
    now = datetime(2026, 6, 11, tzinfo=timezone.utc)
    old = now - timedelta(minutes=auth_service._ATTEMPT_WINDOW_MINUTES + 1)
    fresh = now - timedelta(minutes=1)

    auth_service._FORGOT_FAILURES.clear()
    auth_service._FORGOT_FAILURES["old-user"] = [old]
    auth_service._FORGOT_FAILURES["fresh-user"] = [fresh]

    auth_service._cleanup_forgot_failures(now)

    assert "old-user" not in auth_service._FORGOT_FAILURES
    assert auth_service._FORGOT_FAILURES["fresh-user"] == [fresh]
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
py -m pytest backend\tests\test_forgot_password_rate_limit.py -q
```

Expected: FAIL，原因是 `_cleanup_forgot_failures` 不存在。

- [ ] **Step 3: 实现清理函数**

Modify `backend/app/services/auth_service.py`：

```python
_LAST_FORGOT_FAILURE_CLEANUP: datetime | None = None
_CLEANUP_INTERVAL_MINUTES = 10
```

新增：

```python
def _cleanup_forgot_failures(now: datetime | None = None) -> None:
    """清理所有已过期的忘记密码失败记录，避免长时间运行时字典膨胀。"""
    current = now or datetime.now(timezone.utc)
    cutoff = current - timedelta(minutes=_ATTEMPT_WINDOW_MINUTES)
    expired_users = []
    for user_id, attempts in list(_FORGOT_FAILURES.items()):
        active_attempts = [attempt for attempt in attempts if attempt > cutoff]
        if active_attempts:
            _FORGOT_FAILURES[user_id] = active_attempts
        else:
            expired_users.append(user_id)
    for user_id in expired_users:
        _FORGOT_FAILURES.pop(user_id, None)
```

在 `_check_and_record_failure` 开头加入节流式全局清理：

```python
    global _LAST_FORGOT_FAILURE_CLEANUP
    now = datetime.now(timezone.utc)
    if (
        _LAST_FORGOT_FAILURE_CLEANUP is None
        or now - _LAST_FORGOT_FAILURE_CLEANUP > timedelta(minutes=_CLEANUP_INTERVAL_MINUTES)
    ):
        _cleanup_forgot_failures(now)
        _LAST_FORGOT_FAILURE_CLEANUP = now
```

保留原有当前用户窗口内过滤逻辑。

- [ ] **Step 4: 验证限流测试**

Run:

```powershell
py -m pytest backend\tests\test_forgot_password_rate_limit.py backend\tests\test_auth.py -q
```

Expected: 新增清理测试通过；登录、忘记密码相关测试不回退。

---

### Task 6: 收敛 `format_project` 防御式格式化

**Files:**
- Modify: `backend/app/services/project_service.py`
- Modify: callers in `backend/app/api/v1/routes/project_routes.py`, `backend/app/api/v1/routes/teacher_routes.py`, and other direct callers if needed
- Test: `backend/tests/test_project_course_scope.py`

- [ ] **Step 1: 定位调用点**

Run:

```powershell
rg -n "format_project\(" backend\app backend\tests
```

Expected: 所有调用点都传入 `Project` ORM 对象，或发现需要先转换为 ORM 查询结果的异常输入。

- [ ] **Step 2: 明确函数输入类型**

Modify `backend/app/services/project_service.py`：

```python
def format_project(db: Session, project: Project, user_id: str | None = None) -> dict:
    """将 Project ORM 对象格式化为 API 响应。"""
```

内部变量统一改名为 `project`，删除对确定存在字段的 `hasattr` 防御，例如：

```python
    course_id = project.course_id
    course_name = project.course.name if project.course else ""
    tags = project.tags or []
    featured = bool(project.featured)
```

仅对历史兼容字段保留 `getattr`：

```python
    report_file_id = getattr(project, "report_file_id", None)
```

如果发现所有测试库和正式模型都已有字段，则也删除对应 `getattr`。

- [ ] **Step 3: 减少 N+1 查询**

在列表查询服务中对作品作者、课程、图片做预加载。示例：

```python
from sqlalchemy.orm import joinedload, selectinload

query = db.query(Project).options(
    joinedload(Project.author),
    joinedload(Project.course),
    selectinload(Project.images),
)
```

`format_project` 中作者优先使用 relationship：

```python
    author_name = project.author.name if project.author else ""
```

只有在调用方无法预加载且 relationship 为空时，才允许一次兼容查询：

```python
    if not author_name:
        author = db.query(User).filter(User.id == project.author_id).first()
        author_name = author.name if author else ""
```

- [ ] **Step 4: 验证作品相关测试**

Run:

```powershell
py -m pytest backend\tests\test_project_course_scope.py backend\tests\test_integration_bugfixes.py -q
```

Expected: 作品详情、作品广场、教师审核列表、点赞、批量下载相关测试通过。

---

### Task 7: HTTP 错误状态码兼容迁移

**Files:**
- Modify: `backend/main.py`
- Modify: `backend/app/core/response.py`
- Modify: `frontend/src/api/http.ts`
- Test: `backend/tests/test_http_status_compat.py`

- [ ] **Step 1: 写兼容测试**

Create `backend/tests/test_http_status_compat.py`:

```python
"""业务异常 HTTP 状态码兼容测试。"""

from tests.conftest import auth_header


def test_business_exception_can_return_real_http_status(client, monkeypatch, student_token):
    monkeypatch.setenv("BUSINESS_EXCEPTION_HTTP_STATUS", "real")
    resp = client.get("/api/courses/999999", headers=auth_header(student_token))

    assert resp.status_code == 404
    assert resp.json()["code"] == 404
    assert resp.json()["data"] is None


def test_business_exception_defaults_to_legacy_http_200(client, monkeypatch, student_token):
    monkeypatch.delenv("BUSINESS_EXCEPTION_HTTP_STATUS", raising=False)
    resp = client.get("/api/courses/999999", headers=auth_header(student_token))

    assert resp.status_code == 200
    assert resp.json()["code"] == 404
```

注意：如果 `backend/main.py` 在模块导入时读取环境变量，测试需要改为 monkeypatch 配置对象或直接调用 handler，避免 app 已初始化导致环境变量不生效。

- [ ] **Step 2: 增加后端兼容开关**

Modify `backend/main.py`：

```python
def _business_http_status(code: int) -> int:
    if os.getenv("BUSINESS_EXCEPTION_HTTP_STATUS") == "real":
        return code if 400 <= code <= 599 else 500
    return 200
```

异常处理改为：

```python
@app.exception_handler(BusinessException)
async def business_exception_handler(request: Request, exc: BusinessException):
    return JSONResponse(status_code=_business_http_status(exc.code), content={
        "code": exc.code,
        "data": None,
        "message": exc.message,
    })
```

数据库异常和兜底异常也用同样策略，但默认仍为 200：

```python
status_code = _business_http_status(500)
```

- [ ] **Step 3: 前端拦截器兼容非 2xx**

Modify `frontend/src/api/http.ts`：

```ts
function handleAuthExpired(message: string) {
  localStorage.removeItem('auth_user')
  localStorage.removeItem('auth_token')
  window.location.href = '/login'
  return Promise.reject(new Error(message))
}
```

在 error 分支里继续优先读取 `data.message`：

```ts
const data = error.response?.data
if (data?.code === 401 || error.response?.status === 401) {
  if (isLoginRequest(error.config?.url)) {
    return Promise.reject(new Error(getErrorMessage(error)))
  }
  return handleAuthExpired(data?.message || '登录已过期')
}
const message = getErrorMessage(error)
ElMessage.error(message)
return Promise.reject(new Error(message))
```

保留 success 分支的 `body.code !== 0` 处理，兼容旧 HTTP 200 错误。

- [ ] **Step 4: 验证接口和前端构建**

Run:

```powershell
py -m pytest backend\tests\test_http_status_compat.py backend\tests\test_auth.py -q
npm run build
```

Working directory for `npm run build`: `frontend`

Expected: 新旧模式都可用；前端对非 2xx 错误仍显示业务中文提示。

---

### Task 8: 日期字段类型改造设计，不在本计划直接迁移

**Files:**
- Create: `docs/superpowers/specs/2026-06-11-date-field-migration-design.md`

- [ ] **Step 1: 写独立设计文档**

Create `docs/superpowers/specs/2026-06-11-date-field-migration-design.md`，必须包含：

```markdown
# 日期字段迁移设计

## 目标

将 `materials.date`、`projects.date`、`activity_events.date` 从字符串日期迁移到可排序、可索引的日期或时间类型。

## 当前字段

- `Material.date`: 当前写入 `YYYY-MM-DD`。
- `Project.date`: 当前写入 `YYYY-MM-DD`，作品列表按该字段倒序。
- `ActivityEvent.date`: 当前写入字符串日期，活动事件按日期展示。

## 推荐方案

新增 `created_at` 或 `event_date` 类型字段，保留旧 `date` 作为响应兼容字段。服务层写入新字段，响应格式化继续输出 `date: YYYY-MM-DD`。

## 不推荐方案

直接原地把 `date` 改成 Date，会影响旧库中空字符串、非法字符串和前端类型。

## 数据迁移

1. 新增类型列。
2. 将合法 `YYYY-MM-DD` 字符串回填到新列。
3. 非法或空值按 `created_at` 或当前日期兜底，并输出审计日志。
4. 服务层改为按新列排序。
5. 保留旧 `date` 输出至少一个版本周期。

## 验收

- MySQL 可按新日期列使用索引排序。
- SQLite 测试库通过。
- API 仍返回 `date` 字符串。
```

- [ ] **Step 2: 当前阶段只补索引和排序审计**

Run:

```powershell
rg -n "Project\.date|Material\.date|ActivityEvent|order_by\(.*date" backend\app backend\tests
```

Expected: 明确所有排序和展示调用点，为后续迁移提供清单。

---

### Task 9: User 主键改造设计，不在本计划直接迁移

**Files:**
- Create: `docs/superpowers/specs/2026-06-11-user-primary-key-migration-design.md`

- [ ] **Step 1: 写独立设计文档**

Create `docs/superpowers/specs/2026-06-11-user-primary-key-migration-design.md`，必须包含：

```markdown
# User 主键迁移设计

## 目标

降低跨表 JOIN 成本，同时保留学生学号、教师工号、管理员账号作为登录账号。

## 推荐方案

新增整型 `users.pk` 或 `users.numeric_id` 作为内部主键，保留当前 `users.id` 为唯一业务账号字段。后续逐表增加 `user_pk` 外键并双写，验证完成后再切换 JOIN。

## 不推荐方案

直接把 `users.id` 从字符串改为自增整型。该方案会同时破坏登录、JWT subject、所有外键、测试夹具和前端用户字段。

## 迁移阶段

1. 新增整型唯一内部 ID。
2. 给引用用户的表新增可空 `user_pk`/`author_pk`/`teacher_pk` 等列。
3. 回填映射。
4. 服务层 JOIN 改为优先使用整型列，保留字符串列兼容。
5. 全量验证后再收紧 NOT NULL 和外键。

## 验收

- 登录账号仍是原 `id` 字符串。
- JWT `sub` 在迁移期仍可识别旧账号。
- 所有现有测试夹具不需要一次性重写。
```

- [ ] **Step 2: 生成引用清单**

Run:

```powershell
rg -n "ForeignKey\(\"users\.id\"|user_id|author_id|teacher_id|created_by|resolved_by|created_by = Column\(String" backend\app backend\tests
```

Expected: 得到所有用户字符串外键引用位置，作为独立迁移计划输入。

---

### Task 10: 数据库枚举约束设计

**Files:**
- Modify: `backend/app/db/schema_compat.py`
- Test: `backend/tests/test_schema_compat.py`

- [ ] **Step 1: 先做数据审计，不直接加约束**

Run:

```powershell
rg -n "type=\"|type':|type\\s*=" backend\seed_data.py backend\tests backend\app
```

Expected: 确认可用值集合为：

- 资料：`video`、`pdf`、`link`
- 题目：`choice`、`fill`、`multi_choice`

- [ ] **Step 2: 在兼容层增加 MySQL CHECK 设计**

仅在确认 MySQL 版本支持 CHECK 且无历史脏数据后，给 `backend/app/db/schema_compat.py` 增加幂等约束函数。示例设计：

```python
def _ensure_check_constraint(conn, table: str, name: str, expression: str) -> None:
    """为 MySQL 表补充 CHECK 约束；SQLite 测试库跳过。"""
    if conn.dialect.name != "mysql":
        return
    rows = conn.execute(text("""
        SELECT CONSTRAINT_NAME
        FROM information_schema.TABLE_CONSTRAINTS
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME = :table
          AND CONSTRAINT_NAME = :name
    """), {"table": table, "name": name}).fetchall()
    if not rows:
        conn.execute(text(f"ALTER TABLE {table} ADD CONSTRAINT {name} CHECK ({expression})"))
```

调用：

```python
_ensure_check_constraint(conn, "materials", "ck_materials_type", "type IN ('video', 'pdf', 'link')")
_ensure_check_constraint(conn, "questions", "ck_questions_type", "type IN ('choice', 'fill', 'multi_choice')")
```

如果正式 MySQL 版本不可靠支持 CHECK，则改为只保留 Pydantic 校验和导入服务校验，不做数据库约束。

- [ ] **Step 3: 验证兼容层**

Run:

```powershell
py -m pytest backend\tests\test_schema_compat.py backend\tests\test_type_validation.py -q
```

Expected: SQLite 测试通过；MySQL 约束逻辑在 SQLite 下不执行。

---

### Task 11: 总体验收

**Files:**
- No direct source changes unless previous tasks reveal failures.

- [ ] **Step 1: 后端目标测试**

Run:

```powershell
py -m pytest backend\tests\test_access_control_service.py backend\tests\test_type_validation.py backend\tests\test_forgot_password_rate_limit.py backend\tests\test_http_status_compat.py backend\tests\test_student_course_visibility.py backend\tests\test_project_course_scope.py backend\tests\test_integration_bugfixes.py -q
```

Expected: 全部通过。若现有未提交改动导致历史测试失败，记录具体失败，不扩大本计划范围。

- [ ] **Step 2: 前端验证**

Run:

```powershell
npm run test:no-counter-store
npm run build
```

Working directory: `frontend`

Expected: 静态测试和构建通过。

- [ ] **Step 3: 无关改动检查**

Run:

```powershell
git diff --check
git status --porcelain=v1 -uall
```

Expected: `git diff --check` 无空白错误；`git status` 中新增和修改文件都能对应到本计划任务或执行前已有改动。

- [ ] **Step 4: 同步 graphify**

Run:

```powershell
graphify update .
```

如果命令不可用，运行：

```powershell
& (Get-Content graphify-out\.graphify_python) -m graphify update .
```

Expected: 图谱更新完成。若 graphify 工具失败，在总结中说明，不阻塞业务验收。

## 执行顺序建议

1. 先执行 Task 1 到 Task 5，得到低风险收益。
2. 再执行 Task 6，收敛作品格式化和潜在 N+1 查询。
3. Task 7 单独执行并重点回归前端错误提示。
4. Task 8 和 Task 9 只产出设计文档，不与本轮低风险改动混合实现。
5. Task 10 根据正式 MySQL 版本和历史数据审计结果决定是否加数据库 CHECK。

## 验收口径

- 重复 `_student_can_access_course` 定义清理完成，学生课程权限逻辑有共享测试。
- `counter.ts` 删除且无引用。
- 未知资料类型、未知题目类型不能通过接口写入。
- 忘记密码失败限流字典会定期清理冷 key。
- `format_project` 明确只格式化 `Project` ORM 对象，主要字段不再依赖 `hasattr`。
- HTTP 错误迁移保留统一响应体，并能通过开关兼容旧 HTTP 200 行为。
- 日期字段和用户主键改造有独立设计文档，不混入本轮代码改动。
