using IndexAdvisor.Gui.Core;

namespace IndexAdvisor.Gui.Tests;

public class ChoicePromptParserTests
{
	[Fact]
	public void TryParse_ToolApprovalPrompt_ReturnsQuestionAndChoices()
	{
		var parsed = ChoicePromptParser.TryParse("Виконати дозапит? [П]ідтвердити / [З]мінити / [В]ідхилити", out var question, out var choices);

		Assert.True(parsed);
		Assert.Equal("Виконати дозапит?", question);
		Assert.Equal(
			[new PromptChoice("Підтвердити", "П"), new PromptChoice("Змінити", "З"), new PromptChoice("Відхилити", "В")],
			choices);
	}

	[Theory]
	[InlineData("@TableName (string), поточне: Orders [Enter — без змін, '-' — очистити]")]
	[InlineData("Причина відхилення (Enter — без причини)")]
	[InlineData("Продовжити? [Т]ак")]
	[InlineData("")]
	public void TryParse_PlainPrompts_AreNotChoices(string prompt)
	{
		Assert.False(ChoicePromptParser.TryParse(prompt, out _, out var choices));
		Assert.Empty(choices);
	}

	[Fact]
	public void TryParse_DuplicateKeys_AreNotChoices()
	{
		Assert.False(ChoicePromptParser.TryParse("[Т]ак / [Т]очно", out _, out _));
	}
}
