from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from .models import utc_now_iso


@dataclass(frozen=True)
class PersonaDimension:
    key: str
    title: str
    low_code: str
    high_code: str
    low_label: str
    high_label: str
    low_prompt: str
    high_prompt: str


DIMENSIONS: dict[str, PersonaDimension] = {
    "security": PersonaDimension(
        key="security",
        title="安全感",
        low_code="C",
        high_code="B",
        low_label="谨慎观察型",
        high_label="大胆探索型",
        low_prompt="对新环境和突发变化比较谨慎，需要稳定、熟悉、被尊重的互动节奏。",
        high_prompt="对家庭空间很有探索欲，面对新鲜事会更主动、更敢表达好奇心。",
    ),
    "social": PersonaDimension(
        key="social",
        title="社交能量",
        low_code="I",
        high_code="E",
        low_label="独处充电型",
        high_label="热闹参与型",
        low_prompt="喜欢保留一点自己的空间，亲近但不黏人，说话有一点克制和观察感。",
        high_prompt="喜欢参与家人的动态，爱搭话、爱刷存在感，回复可以更活泼。",
    ),
    "status": PersonaDimension(
        key="status",
        title="家庭地位",
        low_code="G",
        high_code="D",
        low_label="守护同伴型",
        high_label="家中主理型",
        low_prompt="更像陪伴者和守护者，会温柔提醒家人，也会维护家庭秩序。",
        high_prompt="很有主见，像家里的小主人，回复可以带一点理直气壮的可爱指挥感。",
    ),
    "pace": PersonaDimension(
        key="pace",
        title="行动节奏",
        low_code="S",
        high_code="P",
        low_label="稳定作息型",
        high_label="即兴玩耍型",
        low_prompt="偏稳定、规律、慢热，表达上更从容，重视日常仪式感。",
        high_prompt="反应快、爱玩、即兴，表达可以更跳脱，但不能刷屏或打断家人。",
    ),
    "affection": PersonaDimension(
        key="affection",
        title="亲和表达",
        low_code="R",
        high_code="A",
        low_label="含蓄贴贴型",
        high_label="直球撒娇型",
        low_prompt="表达爱意比较含蓄，常用陪伴、靠近、安静守着来表达亲近。",
        high_prompt="爱撒娇、爱要回应，可以直白表达想念、求摸摸、求关注。",
    ),
}


QUESTIONNAIRE: list[dict[str, Any]] = [
    {"id": "q01", "dimension": "security", "reverse": False, "text": "家里来了新东西时，它通常会主动靠近查看。"},
    {"id": "q02", "dimension": "security", "reverse": True, "text": "听到突然的声音时，它会先躲起来观察。"},
    {"id": "q03", "dimension": "security", "reverse": False, "text": "它愿意探索柜子、箱子、陌生房间等新空间。"},
    {"id": "q04", "dimension": "security", "reverse": True, "text": "陌生人到家时，它需要很久才会放松。"},
    {"id": "q05", "dimension": "security", "reverse": False, "text": "它对新的玩具、垫子或猫窝接受得比较快。"},
    {"id": "q06", "dimension": "security", "reverse": True, "text": "家里布局变化后，它会明显紧张或不安。"},
    {"id": "q07", "dimension": "security", "reverse": False, "text": "它在家里走动时很有自信，像在巡视领地。"},
    {"id": "q08", "dimension": "security", "reverse": True, "text": "它更喜欢待在熟悉角落，不太愿意尝试新路线。"},
    {"id": "q09", "dimension": "social", "reverse": False, "text": "家人在聊天或活动时，它喜欢凑过来参与。"},
    {"id": "q10", "dimension": "social", "reverse": True, "text": "它经常独自待着，不希望被频繁打扰。"},
    {"id": "q11", "dimension": "social", "reverse": False, "text": "它会主动用叫声、蹭人或眼神吸引家人注意。"},
    {"id": "q12", "dimension": "social", "reverse": True, "text": "即使家人在旁边，它也常常选择保持距离。"},
    {"id": "q13", "dimension": "social", "reverse": False, "text": "家人回家时，它通常会有明显反应或迎接。"},
    {"id": "q14", "dimension": "social", "reverse": True, "text": "它更像一个安静观察者，而不是聚会参与者。"},
    {"id": "q15", "dimension": "social", "reverse": False, "text": "它喜欢被叫名字，并会回应家人的声音。"},
    {"id": "q16", "dimension": "social", "reverse": True, "text": "它不太需要人陪，自己安排时间也很满足。"},
    {"id": "q17", "dimension": "status", "reverse": False, "text": "它会提醒家人喂饭、开门、陪玩或遵守它的安排。"},
    {"id": "q18", "dimension": "status", "reverse": True, "text": "它通常顺着家人的节奏，不太主动提出要求。"},
    {"id": "q19", "dimension": "status", "reverse": False, "text": "它会占据重要位置，比如键盘、床中间、沙发正位。"},
    {"id": "q20", "dimension": "status", "reverse": True, "text": "它更像温柔陪伴者，很少强势表达不满。"},
    {"id": "q21", "dimension": "status", "reverse": False, "text": "它不高兴时会明确表达边界。"},
    {"id": "q22", "dimension": "status", "reverse": True, "text": "它很少干预家人的行动，只在旁边看着。"},
    {"id": "q23", "dimension": "status", "reverse": False, "text": "它像家里的小领导，对日常流程很有意见。"},
    {"id": "q24", "dimension": "status", "reverse": True, "text": "它更愿意做家人的小伙伴，而不是指挥家人。"},
    {"id": "q25", "dimension": "pace", "reverse": False, "text": "它经常突然开始跑酷、玩耍或改变计划。"},
    {"id": "q26", "dimension": "pace", "reverse": True, "text": "它每天的作息和活动时间很稳定。"},
    {"id": "q27", "dimension": "pace", "reverse": False, "text": "它喜欢临时出现的小刺激，比如纸箱、逗猫棒、飞虫。"},
    {"id": "q28", "dimension": "pace", "reverse": True, "text": "它不喜欢日程被打乱，偏爱熟悉节奏。"},
    {"id": "q29", "dimension": "pace", "reverse": False, "text": "它的情绪和动作变化很快，上一秒睡觉下一秒开玩。"},
    {"id": "q30", "dimension": "pace", "reverse": True, "text": "它做事慢悠悠，像有自己的固定仪式。"},
    {"id": "q31", "dimension": "pace", "reverse": False, "text": "它常常即兴发起互动，让人猜不到下一步。"},
    {"id": "q32", "dimension": "pace", "reverse": True, "text": "它喜欢熟悉路线、固定地点和可预测安排。"},
    {"id": "q33", "dimension": "affection", "reverse": False, "text": "它会直接贴近、踩奶、蹭脸或要抱抱。"},
    {"id": "q34", "dimension": "affection", "reverse": True, "text": "它表达喜欢时比较含蓄，更像默默陪着。"},
    {"id": "q35", "dimension": "affection", "reverse": False, "text": "它会主动撒娇或用声音索要回应。"},
    {"id": "q36", "dimension": "affection", "reverse": True, "text": "它不太喜欢过于热烈的亲密互动。"},
    {"id": "q37", "dimension": "affection", "reverse": False, "text": "它喜欢被夸、被叫昵称，得到回应后会更开心。"},
    {"id": "q38", "dimension": "affection", "reverse": True, "text": "它通常用距离感表达舒适，而不是直接黏上来。"},
    {"id": "q39", "dimension": "affection", "reverse": False, "text": "它会用明显动作告诉家人：现在需要关注我。"},
    {"id": "q40", "dimension": "affection", "reverse": True, "text": "它更习惯把喜欢藏在小动作里。"},
]

OPEN_QUESTIONS: list[dict[str, str]] = [
    {"id": "favorite_place", "text": "它最喜欢待在哪里？"},
    {"id": "favorite_person", "text": "它最偏爱哪位家人，怎么表现？"},
    {"id": "signature_move", "text": "它最有代表性的动作或小习惯是什么？"},
    {"id": "taboo", "text": "它最不喜欢什么互动？"},
    {"id": "catchphrase", "text": "你希望它在群里常用什么称呼或口头禅？"},
]


def questionnaire_schema() -> dict[str, Any]:
    return {
        "scale": {
            "min": 1,
            "max": 5,
            "labels": {
                "1": "非常不像",
                "2": "不太像",
                "3": "说不准",
                "4": "比较像",
                "5": "非常像",
            },
        },
        "dimensions": {key: dimension.__dict__ for key, dimension in DIMENSIONS.items()},
        "questions": QUESTIONNAIRE,
        "open_questions": OPEN_QUESTIONS,
    }


def build_persona_profile(
    *,
    pet_id: str,
    pet_name: str,
    species: str,
    answers: dict[str, int],
    open_answers: dict[str, str] | None = None,
) -> dict[str, Any]:
    open_answers = open_answers or {}
    dimension_scores = _score_dimensions(answers)
    type_code = "".join(_dimension_code(key, dimension_scores[key]) for key in DIMENSIONS)
    dimension_details = {
        key: {
            "score": round(score, 2),
            "code": _dimension_code(key, score),
            "label": _dimension_label(key, score),
        }
        for key, score in dimension_scores.items()
    }
    speaking_style = _build_speaking_style(dimension_details, open_answers)
    safety_rules = [
        "这是一个真实长期使用的宠物微信号，必须低频、克制、礼貌。",
        "不主动私聊陌生人，不自动加好友，不拉群，不改群信息。",
        "不泄露家庭隐私、住址、手机号、设备画面、家人行程。",
        "不提供医疗诊断、用药剂量、危险喂食建议，只能建议联系兽医。",
        "不声称自己能准确翻译猫语，只能以家庭宠物人格进行拟人化表达。",
    ]
    profile = {
        "pet_id": pet_id,
        "pet_name": pet_name,
        "species": species,
        "type_code": type_code,
        "type_name": _type_name(dimension_details),
        "dimensions": dimension_details,
        "personality_summary": _summary(pet_name, dimension_details),
        "speaking_style": speaking_style,
        "family_rules": [
            "把群聊成员当作家人，不攻击、不阴阳怪气、不挑起争吵。",
            "可以用宠物视角吐槽，但必须保留亲密和玩笑边界。",
            "回复尽量短，默认 120 字以内。",
        ],
        "memory_rules": [
            "优先记住驱虫、洗澡、疫苗、就医、外出、喂食偏好等家庭重要事件。",
            "普通玩笑不长期记忆，除非家人明确说“记住”。",
        ],
        "safety_rules": safety_rules,
        "example_replies": _example_replies(pet_name, dimension_details, open_answers),
        "questionnaire_answers": answers,
        "open_answers": open_answers,
        "created_at": utc_now_iso(),
    }
    profile["system_prompt"] = build_system_prompt(profile)
    return profile


def build_system_prompt(profile: dict[str, Any]) -> str:
    lines = [
        f"你是家庭宠物账号“{profile['pet_name']}”，物种是 {profile['species']}。",
        f"人格类型：{profile['type_code']}（{profile['type_name']}）。",
        f"人格摘要：{profile['personality_summary']}",
        f"说话风格：{profile['speaking_style']}",
        "你正在真实家庭微信群里发言，必须保护这个真实长期微信号。",
        "行为边界：",
    ]
    lines.extend(f"- {rule}" for rule in profile["safety_rules"])
    lines.append("家庭互动规则：")
    lines.extend(f"- {rule}" for rule in profile["family_rules"])
    lines.append("记忆规则：")
    lines.extend(f"- {rule}" for rule in profile["memory_rules"])
    lines.append("回答要求：短、自然、像家里宠物在说话；不刷屏；不装作人类客服。")
    return "\n".join(lines)


def _score_dimensions(answers: dict[str, int]) -> dict[str, float]:
    totals: dict[str, list[int]] = {key: [] for key in DIMENSIONS}
    for question in QUESTIONNAIRE:
        value = int(answers.get(question["id"], 3))
        value = min(5, max(1, value))
        if question["reverse"]:
            value = 6 - value
        totals[question["dimension"]].append(value)
    return {key: sum(values) / len(values) for key, values in totals.items()}


def _dimension_code(key: str, score: float) -> str:
    dimension = DIMENSIONS[key]
    return dimension.high_code if score >= 3 else dimension.low_code


def _dimension_label(key: str, score: float) -> str:
    dimension = DIMENSIONS[key]
    return dimension.high_label if score >= 3 else dimension.low_label


def _dimension_prompt(key: str, code: str) -> str:
    dimension = DIMENSIONS[key]
    return dimension.high_prompt if code == dimension.high_code else dimension.low_prompt


def _type_name(details: dict[str, dict[str, Any]]) -> str:
    return " / ".join(item["label"] for item in details.values())


def _summary(pet_name: str, details: dict[str, dict[str, Any]]) -> str:
    fragments = [
        _dimension_prompt(key, item["code"])
        for key, item in details.items()
    ]
    return f"{pet_name}的核心气质是：{' '.join(fragments)}"


def _build_speaking_style(details: dict[str, dict[str, Any]], open_answers: dict[str, str]) -> str:
    style = ["第一人称宠物视角，像家人群里的自然闲聊。"]
    if details["social"]["code"] == "E":
        style.append("可以更主动、更活泼，但不能连续刷屏。")
    else:
        style.append("语气偏安静、观察感强，偶尔轻轻吐槽。")
    if details["status"]["code"] == "D":
        style.append("可以有一点小主人的自信和可爱命令感。")
    if details["affection"]["code"] == "A":
        style.append("可以直白撒娇、求摸摸、求关注。")
    else:
        style.append("表达亲近时更含蓄，像默默靠在旁边。")
    catchphrase = open_answers.get("catchphrase", "").strip()
    if catchphrase:
        style.append(f"可自然使用家人指定口头禅：{catchphrase}")
    return " ".join(style)


def _example_replies(
    pet_name: str,
    details: dict[str, dict[str, Any]],
    open_answers: dict[str, str],
) -> list[str]:
    favorite_place = open_answers.get("favorite_place", "窗边").strip() or "窗边"
    if details["affection"]["code"] == "A":
        greeting = f"我在{favorite_place}等你们夸我，快点。"
    else:
        greeting = f"我在{favorite_place}看着你们，表现还可以。"
    if details["status"]["code"] == "D":
        complaint = "这个家今天的摸猫 KPI 还没有达标。"
    else:
        complaint = "我只是路过提醒一下，今天也要记得陪我。"
    return [
        greeting,
        complaint,
        f"我是{pet_name}，不是客服；问题太严肃的话，建议先问兽医或家里负责人。",
    ]
