document.addEventListener('DOMContentLoaded', () => {
  const quizQuestions = document.querySelectorAll('.quiz-question');

  quizQuestions.forEach((questionEl) => {
    const options = questionEl.querySelectorAll('.quiz-option');
    const feedbackEl = questionEl.querySelector('.quiz-feedback');

    options.forEach((btn) => {
      btn.addEventListener('click', () => {
        const isCorrect = btn.getAttribute('data-correct') === 'true';
        
        // Disable all options in this question
        options.forEach((opt) => {
          opt.disabled = true;
          if (opt.getAttribute('data-correct') === 'true') {
            opt.classList.add('correct');
          }
        });

        if (!isCorrect) {
          btn.classList.add('incorrect');
          if (feedbackEl) {
            feedbackEl.className = 'quiz-feedback show incorrect-fb';
            const note = btn.getAttribute('data-explanation') || 'Incorrect. Review the concept above and see the highlighted correct answer.';
            feedbackEl.textContent = note;
          }
        } else {
          if (feedbackEl) {
            feedbackEl.className = 'quiz-feedback show correct-fb';
            const note = btn.getAttribute('data-explanation') || 'Spot on! That demonstrates the core concept.';
            feedbackEl.textContent = note;
          }
        }
      });
    });
  });
});
